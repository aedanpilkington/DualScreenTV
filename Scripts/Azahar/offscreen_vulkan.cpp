// DualScreenTV offscreen Vulkan adapter. GPL-2.0-or-later.
// The core renders on Metal through MoltenVK. A bounded native-resolution
// readback keeps the frontend's TV snapshots and companion transport unchanged.
#include "offscreen_vulkan.h"
#include "libretro_vulkan.h"
#include <cstdio>
#include <cstring>
#include <mutex>
#include <stdexcept>
#include <vector>

namespace DSTVOffscreen {
namespace {
retro_environment_t environment;
retro_video_refresh_t video;
retro_hw_render_callback* hardware;
const retro_hw_render_context_negotiation_interface_vulkan* negotiation;
retro_hw_render_interface_vulkan interface{};
retro_vulkan_context context{};
VkInstance instance;
VkCommandPool pool;
VkCommandBuffer command;
VkFence fence;
VkBuffer buffer;
VkDeviceMemory memory;
void* mapped;
size_t capacity;
const retro_vulkan_image* image;
std::vector<VkSemaphore> waits;
std::vector<VkCommandBuffer> pending_commands;
VkSemaphore signal;
std::vector<uint32_t> pixels;
std::mutex queue_mutex;

void Check(VkResult result) {
    if (result != VK_SUCCESS) throw std::runtime_error("Offscreen Vulkan error " + std::to_string(result));
}
void Lock(void*) { queue_mutex.lock(); }
void Unlock(void*) { queue_mutex.unlock(); }
uint32_t Index(void*) { return 0; }
uint32_t Mask(void*) { return 1; }
void Wait(void*) {
    // Video() waits for the readback fence before returning. With one sync
    // index, the previous presentation is already finished here. Waiting for
    // the whole graphics queue also stalls unrelated current-frame work.
}
void SetImage(void*, const retro_vulkan_image* next, uint32_t count,
              const VkSemaphore* semaphores, uint32_t family) {
    if (family != VK_QUEUE_FAMILY_IGNORED && family != context.queue_family_index)
        throw std::runtime_error("Offscreen Vulkan requires the shared graphics queue");
    image = next;
    waits.clear();
    if (count) waits.assign(semaphores, semaphores + count);
}
void SetCommands(void*, uint32_t count, const VkCommandBuffer* commands) {
    if (count) pending_commands.insert(pending_commands.end(), commands, commands + count);
}
void SetSignal(void*, VkSemaphore semaphore) { signal = semaphore; }

void FreeBuffer() {
    if (mapped) vkUnmapMemory(context.device, memory);
    if (buffer) vkDestroyBuffer(context.device, buffer, nullptr);
    if (memory) vkFreeMemory(context.device, memory, nullptr);
    mapped = nullptr; buffer = VK_NULL_HANDLE; memory = VK_NULL_HANDLE; capacity = 0;
}
void EnsureBuffer(size_t bytes) {
    if (capacity >= bytes) return;
    FreeBuffer();
    VkBufferCreateInfo info{VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO};
    info.size = bytes;
    info.usage = VK_BUFFER_USAGE_TRANSFER_DST_BIT;
    info.sharingMode = VK_SHARING_MODE_EXCLUSIVE;
    Check(vkCreateBuffer(context.device, &info, nullptr, &buffer));
    VkMemoryRequirements requirements;
    vkGetBufferMemoryRequirements(context.device, buffer, &requirements);
    VkPhysicalDeviceMemoryProperties properties;
    vkGetPhysicalDeviceMemoryProperties(context.gpu, &properties);
    uint32_t type = properties.memoryTypeCount;
    for (uint32_t i = 0; i < properties.memoryTypeCount; ++i) {
        const auto flags = properties.memoryTypes[i].propertyFlags;
        if ((requirements.memoryTypeBits & (1u << i)) &&
            (flags & (VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT)) ==
                (VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT)) {
            type = i; break;
        }
    }
    if (type == properties.memoryTypeCount) throw std::runtime_error("No coherent readback memory");
    VkMemoryAllocateInfo allocation{VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO};
    allocation.allocationSize = requirements.size;
    allocation.memoryTypeIndex = type;
    Check(vkAllocateMemory(context.device, &allocation, nullptr, &memory));
    Check(vkBindBufferMemory(context.device, buffer, memory, 0));
    Check(vkMapMemory(context.device, memory, 0, VK_WHOLE_SIZE, 0, &mapped));
    capacity = bytes;
}
void Video(const void* data, unsigned width, unsigned height, size_t pitch) {
    if (data != RETRO_HW_FRAME_BUFFER_VALID) { video(data, width, height, pitch); return; }
    // Accept only bounded 1x–4x stacked 3DS layouts; preserve rendered detail.
    if (!image || width < 400 || width > 1600 || width % 400 || height != 480 * (width / 400)) { video(nullptr, 0, 0, 0); return; }
    const auto format = image->create_info.format;
    const bool rgba = format == VK_FORMAT_R8G8B8A8_UNORM || format == VK_FORMAT_R8G8B8A8_SRGB;
    const bool bgra = format == VK_FORMAT_B8G8R8A8_UNORM || format == VK_FORMAT_B8G8R8A8_SRGB;
    if (!rgba && !bgra) throw std::runtime_error("Unsupported readback format");
    const size_t count = size_t(width) * height;
    EnsureBuffer(count * 4);
    Check(vkResetCommandPool(context.device, pool, 0));
    VkCommandBufferBeginInfo begin{VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO};
    begin.flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
    Check(vkBeginCommandBuffer(command, &begin));
    VkImageMemoryBarrier barrier{VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER};
    barrier.srcAccessMask = VK_ACCESS_MEMORY_WRITE_BIT;
    barrier.dstAccessMask = VK_ACCESS_TRANSFER_READ_BIT;
    barrier.oldLayout = image->image_layout;
    barrier.newLayout = VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL;
    barrier.srcQueueFamilyIndex = barrier.dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
    barrier.image = image->create_info.image;
    barrier.subresourceRange = image->create_info.subresourceRange;
    vkCmdPipelineBarrier(command, VK_PIPELINE_STAGE_ALL_COMMANDS_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT,
                         0, 0, nullptr, 0, nullptr, 1, &barrier);
    VkBufferImageCopy copy{};
    copy.imageSubresource = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1};
    copy.imageExtent = {width, height, 1};
    vkCmdCopyImageToBuffer(command, barrier.image, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, buffer, 1, &copy);
    barrier.srcAccessMask = VK_ACCESS_TRANSFER_READ_BIT;
    barrier.dstAccessMask = VK_ACCESS_MEMORY_READ_BIT | VK_ACCESS_MEMORY_WRITE_BIT;
    barrier.oldLayout = VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL;
    barrier.newLayout = image->image_layout;
    vkCmdPipelineBarrier(command, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_ALL_COMMANDS_BIT,
                         0, 0, nullptr, 0, nullptr, 1, &barrier);
    VkBufferMemoryBarrier host{VK_STRUCTURE_TYPE_BUFFER_MEMORY_BARRIER};
    host.srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT;
    host.dstAccessMask = VK_ACCESS_HOST_READ_BIT;
    host.srcQueueFamilyIndex = host.dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
    host.buffer = buffer; host.size = VK_WHOLE_SIZE;
    vkCmdPipelineBarrier(command, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_HOST_BIT,
                         0, 0, nullptr, 1, &host, 0, nullptr);
    Check(vkEndCommandBuffer(command));
    pending_commands.push_back(command);
    std::vector<VkPipelineStageFlags> stages(waits.size(), VK_PIPELINE_STAGE_ALL_COMMANDS_BIT);
    VkSubmitInfo submit{VK_STRUCTURE_TYPE_SUBMIT_INFO};
    submit.waitSemaphoreCount = uint32_t(waits.size());
    submit.pWaitSemaphores = waits.data(); submit.pWaitDstStageMask = stages.data();
    submit.commandBufferCount = uint32_t(pending_commands.size());
    submit.pCommandBuffers = pending_commands.data();
    submit.signalSemaphoreCount = signal ? 1 : 0; submit.pSignalSemaphores = &signal;
    Check(vkResetFences(context.device, 1, &fence));
    {
        std::lock_guard lock(queue_mutex);
        Check(vkQueueSubmit(context.queue, 1, &submit, fence));
    }
    Check(vkWaitForFences(context.device, 1, &fence, VK_TRUE, UINT64_MAX));
    waits.clear(); pending_commands.clear(); signal = VK_NULL_HANDLE;
    pixels.resize(count);
    const auto* source = static_cast<const uint32_t*>(mapped);
    // libretro XRGB8888 is B,G,R,X in little-endian memory.
    for (size_t i = 0; i < count; ++i) {
        uint32_t p = source[i];
        pixels[i] = rgba ? ((p & 0xff00ff00u) | ((p & 0xffu) << 16) | ((p >> 16) & 0xffu)) : p;
    }
    video(pixels.data(), width, height, width * 4);
}

bool Environment(unsigned cmd, void* data) {
    if (!data) return environment(cmd, data);
    switch (cmd) {
    case RETRO_ENVIRONMENT_SET_HW_RENDER: {
        auto* cb = static_cast<retro_hw_render_callback*>(data);
        if (cb->context_type != RETRO_HW_CONTEXT_VULKAN) return false;
        hardware = cb; return true;
    }
    case RETRO_ENVIRONMENT_SET_HW_RENDER_CONTEXT_NEGOTIATION_INTERFACE:
        negotiation = static_cast<const retro_hw_render_context_negotiation_interface_vulkan*>(data);
        return negotiation->interface_type == RETRO_HW_RENDER_CONTEXT_NEGOTIATION_INTERFACE_VULKAN;
    case RETRO_ENVIRONMENT_GET_HW_RENDER_INTERFACE:
        *static_cast<const retro_hw_render_interface_vulkan**>(data) = instance ? &interface : nullptr;
        return instance != VK_NULL_HANDLE;
    default: return environment(cmd, data);
    }
}
} // namespace
retro_environment_t WrapEnvironment(retro_environment_t cb) { environment = cb; return Environment; }
retro_video_refresh_t WrapVideo(retro_video_refresh_t cb) { video = cb; return Video; }

bool Initialize() {
    try {
        if (!hardware || !negotiation || !negotiation->create_device) return false;
        // We link MoltenVK directly, without the desktop Vulkan loader.
        const char* extensions[] = {VK_KHR_SURFACE_EXTENSION_NAME,
            VK_KHR_GET_PHYSICAL_DEVICE_PROPERTIES_2_EXTENSION_NAME};
        VkInstanceCreateInfo info{VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO};
        info.pApplicationInfo = negotiation->get_application_info();
        info.enabledExtensionCount = 2; info.ppEnabledExtensionNames = extensions;
        Check(vkCreateInstance(&info, nullptr, &instance));
        uint32_t count = 0;
        Check(vkEnumeratePhysicalDevices(instance, &count, nullptr));
        if (!count) throw std::runtime_error("No Metal-backed Vulkan GPU");
        std::vector<VkPhysicalDevice> devices(count);
        Check(vkEnumeratePhysicalDevices(instance, &count, devices.data()));
        VkPhysicalDeviceFeatures required{};
        if (!negotiation->create_device(&context, instance, devices[0], VK_NULL_HANDLE,
            vkGetInstanceProcAddr, nullptr, 0, nullptr, 0, &required))
            throw std::runtime_error("Vulkan device negotiation failed");
        VkPhysicalDeviceProperties properties;
        vkGetPhysicalDeviceProperties(context.gpu, &properties);
        printf("DualScreenTV GPU: %s (Vulkan / Metal, CPU JIT disabled)\n", properties.deviceName);
        interface.interface_type = RETRO_HW_RENDER_INTERFACE_VULKAN;
        interface.interface_version = RETRO_HW_RENDER_INTERFACE_VULKAN_VERSION;
        interface.handle = &interface;
        interface.instance = instance; interface.gpu = context.gpu; interface.device = context.device;
        interface.get_device_proc_addr = vkGetDeviceProcAddr;
        interface.get_instance_proc_addr = vkGetInstanceProcAddr;
        interface.queue = context.queue; interface.queue_index = context.queue_family_index;
        interface.set_image = SetImage; interface.get_sync_index = Index;
        interface.get_sync_index_mask = Mask; interface.set_command_buffers = SetCommands;
        interface.wait_sync_index = Wait; interface.lock_queue = Lock; interface.unlock_queue = Unlock;
        interface.set_signal_semaphore = SetSignal;
        VkCommandPoolCreateInfo pool_info{VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO};
        pool_info.queueFamilyIndex = context.queue_family_index;
        pool_info.flags = VK_COMMAND_POOL_CREATE_TRANSIENT_BIT;
        Check(vkCreateCommandPool(context.device, &pool_info, nullptr, &pool));
        VkCommandBufferAllocateInfo allocate{VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO};
        allocate.commandPool = pool; allocate.level = VK_COMMAND_BUFFER_LEVEL_PRIMARY;
        allocate.commandBufferCount = 1;
        Check(vkAllocateCommandBuffers(context.device, &allocate, &command));
        VkFenceCreateInfo fence_info{VK_STRUCTURE_TYPE_FENCE_CREATE_INFO};
        Check(vkCreateFence(context.device, &fence_info, nullptr, &fence));
        hardware->context_reset();
        return true;
    } catch (const std::exception& error) {
        fprintf(stderr, "DualScreenTV GPU initialization: %s\n", error.what());
        return false;
    }
}
void Shutdown() {
    if (context.device) {
        vkDeviceWaitIdle(context.device);
        FreeBuffer();
        if (fence) vkDestroyFence(context.device, fence, nullptr);
        if (pool) vkDestroyCommandPool(context.device, pool, nullptr);
        if (negotiation && negotiation->destroy_device) negotiation->destroy_device();
        vkDestroyDevice(context.device, nullptr);
    }
    if (instance) vkDestroyInstance(instance, nullptr);
    instance = VK_NULL_HANDLE; context = {}; interface = {};
    pool = VK_NULL_HANDLE; fence = VK_NULL_HANDLE; command = VK_NULL_HANDLE;
    image = nullptr; signal = VK_NULL_HANDLE; hardware = nullptr; negotiation = nullptr;
    waits.clear(); pending_commands.clear(); pixels.clear();
}
} // namespace DSTVOffscreen
