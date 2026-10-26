use std::{sync::Arc, time::{Instant, Duration}};
use dust_core::{emu, cpu::interpreter::Interpreter, audio, rtc, spi::firmware, flash::Flash, ds_slot, SaveContents, Model, utils::mem_prelude::*};
#[no_mangle]
pub unsafe extern "C" fn dstv_dust_benchmark(rom: *const std::ffi::c_char, shift: u32, output: *const std::ffi::c_char) -> i32 {
 let path = std::ffi::CStr::from_ptr(rom).to_string_lossy().into_owned();
 let output = std::ffi::CStr::from_ptr(output).to_string_lossy().into_owned();
 pollster::block_on(run(vec!["dust-bench".into(), path, shift.to_string()], Some(output)));
 0
}
async fn run(args: Vec<String>, output: Option<String>) {
 let shift: u8 = args.get(2).map(|v|v.parse().unwrap()).unwrap_or(2);
 let instance = wgpu::Instance::new(wgpu::InstanceDescriptor { backends: wgpu::Backends::METAL, ..Default::default() });
 let adapter = instance.request_adapter(&wgpu::RequestAdapterOptions::default()).await.unwrap();
 println!("Dust backend: {:?}", adapter.get_info());
 let (device, queue) = adapter.request_device(&wgpu::DeviceDescriptor { label: None, required_features: wgpu::Features::empty(), required_limits: wgpu::Limits { max_texture_dimension_2d: 4096, max_bind_groups: 5, ..wgpu::Limits::downlevel_webgl2_defaults() }, memory_hints: wgpu::MemoryHints::MemoryUsage }, None).await.unwrap();
 let device = Arc::new(device); let queue = Arc::new(queue);
 let (tx, rx, _channels3, data) = dust_wgpu_3d::threaded::init(device.clone(), queue.clone(), 1u8 << shift);
 let rx3 = dust_wgpu_2d::Renderer3dRx::Accel { rx: Box::new(rx), color_output_view: data.color_output_view, color_output_view_rx: data.color_output_view_rx, last_submitted_frame: data.last_submitted_frame };
 let (renderer2, _view, channels) = dust_wgpu_2d::threaded::lockstep_scanlines::Renderer::new(device.clone(), queue.clone(), 1u8 << shift, rx3);
 let bytes = std::fs::read(&args[1]).unwrap(); let mut rom = BoxedByteSlice::new_zeroed(bytes.len()); rom.copy_from_slice(&bytes);
 let fw = Flash::new(SaveContents::Existing(firmware::default(Model::Ds)), firmware::id_for_model(Model::Ds)).ok().unwrap();
 let save = ds_slot::spi::flash::Flash::new(SaveContents::New(0x80000), [0;20], true).ok().unwrap();
 let builder = emu::Builder::new(fw, Some(Box::new(rom)), save.into(), Box::new(audio::DummyBackend), None, Box::new(rtc::DummyBackend), Box::new(renderer2), Box::new(tx), None);
 let mut emu = builder.build(Interpreter).ok().expect("build core");
 let width = 256u32 << shift; let height = 384u32 << shift;
 let buffer = device.create_buffer(&wgpu::BufferDescriptor { label: None, size: u64::from(width*height*4), usage: wgpu::BufferUsages::COPY_DST | wgpu::BufferUsages::MAP_READ, mapped_at_creation: false });
 let start = Instant::now(); let mut window = Instant::now();
 for n in 1..=6500u64 {
  if !matches!(emu.run(), emu::RunOutput::FrameFinished) { panic!("guest stopped"); }
  let wait = Instant::now();
  while channels.submitted_frame() < n { assert!(wait.elapsed() < Duration::from_secs(5), "renderer stalled at {} (got {})", n, channels.submitted_frame()); std::thread::yield_now(); }
  let texture = channels.output_texture().unwrap();
  let mut encoder = device.create_command_encoder(&Default::default());
  encoder.copy_texture_to_buffer(wgpu::ImageCopyTexture { texture: &texture, mip_level: 0, origin: wgpu::Origin3d::ZERO, aspect: wgpu::TextureAspect::All }, wgpu::ImageCopyBuffer { buffer: &buffer, layout: wgpu::ImageDataLayout { offset: 0, bytes_per_row: Some(width*4), rows_per_image: Some(height) } }, wgpu::Extent3d { width, height, depth_or_array_layers: 1 });
  queue.submit([encoder.finish()]);
  let slice = buffer.slice(..); let (sent, received) = std::sync::mpsc::channel();
  slice.map_async(wgpu::MapMode::Read, move |r| { let _ = sent.send(r); });
  device.poll(wgpu::Maintain::Wait); received.recv().unwrap().unwrap();
  if n == 6000 { std::fs::write(output.clone().unwrap_or_else(||format!("/tmp/dstv-dust-{}x.rgba", 1 << shift)), &*slice.get_mapped_range()).unwrap(); }
  buffer.unmap();
  if n % 300 == 0 { println!("Dust {}x frame {}: {:.3} ms/tick", 1 << shift, n, window.elapsed().as_secs_f64()*1000.0/300.0); window = Instant::now(); }
 }
 println!("Dust total: {:?}", start.elapsed());
}
