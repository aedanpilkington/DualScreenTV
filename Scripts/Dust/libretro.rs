// DualScreenTV experimental Dust adapter. GPL-3.0-or-later, matching Dust.
// All libretro entry points are called serially by the frontend's core owner.
#![allow(static_mut_refs)]
use dust_core::{
    audio,
    cpu::interpreter::Interpreter,
    ds_slot,
    emu::{self, input::Keys},
    flash::Flash,
    rtc,
    spi::firmware,
    utils::mem_prelude::*,
    Model, SaveContents,
};
use std::{
    ffi::{c_char, c_void, CStr},
    path::PathBuf,
    sync::Arc,
    time::{Duration, Instant},
};
type Env = unsafe extern "C" fn(u32, *mut c_void) -> bool;
type Video = unsafe extern "C" fn(*const c_void, u32, u32, usize);
type Audio = unsafe extern "C" fn(*const i16, usize) -> usize;
type Input = unsafe extern "C" fn(u32, u32, u32, u32) -> i16;
static mut ENV: Option<Env> = None;
static mut VIDEO: Option<Video> = None;
static mut AUDIO: Option<Audio> = None;
static mut INPUT: Option<Input> = None;
static mut POLL: Option<unsafe extern "C" fn()> = None;
static mut CORE: Option<Core> = None;
static mut ROM_PATH: Option<PathBuf> = None;
#[repr(C)]
pub struct Variable {
    key: *const c_char,
    value: *const c_char,
}
#[repr(C)]
pub struct Game {
    path: *const c_char,
    data: *const c_void,
    size: usize,
    meta: *const c_char,
}
#[repr(C)]
pub struct Geometry {
    width: u32,
    height: u32,
    max_width: u32,
    max_height: u32,
    aspect: f32,
}
#[repr(C)]
pub struct Timing {
    fps: f64,
    sample_rate: f64,
}
#[repr(C)]
pub struct Av {
    geometry: Geometry,
    timing: Timing,
}
#[repr(C)]
pub struct Info {
    name: *const c_char,
    version: *const c_char,
    extensions: *const c_char,
    fullpath: bool,
    block_extract: bool,
}
unsafe fn variable(key: &'static [u8]) -> Option<String> {
    let mut v = Variable {
        key: key.as_ptr().cast(),
        value: std::ptr::null(),
    };
    if ENV?(15, (&mut v as *mut Variable).cast()) && !v.value.is_null() {
        Some(CStr::from_ptr(v.value).to_string_lossy().into_owned())
    } else {
        None
    }
}
unsafe fn scale() -> u8 {
    let factor = variable(b"dust_resolution\0")
        .and_then(|v| v.parse::<u32>().ok())
        .unwrap_or(4)
        .clamp(1, 8);
    sanitize_scale(factor)
}
unsafe fn output_scale(s: u8) -> u8 {
    if variable(b"dust_output_limit\0").as_deref() == Some("8") {
        s
    } else {
        s.min(4)
    }
}
unsafe fn output_rate() -> u32 {
    if variable(b"dust_output_rate\0").as_deref() == Some("30") {
        30
    } else {
        60
    }
}
fn sanitize_scale(factor: u32) -> u8 {
    factor.clamp(1, 8) as u8
}
fn pcm_sample(sample: u16) -> i16 {
    ((sample as i32 - 512) << 6) as i16
}
fn touch_axis(value: i16, extent: i32) -> u16 {
    ((value as i32 + 32767) * extent / 65534).clamp(0, extent - 1) as u16
}
struct Clock {
    offset: i64,
}
impl Clock {
    fn now(&self) -> (rtc::Date, rtc::Time) {
        let seconds = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap_or_default()
            .as_secs() as i64
            + self.offset;
        let mut tm: libc::tm = unsafe { std::mem::zeroed() };
        let value = seconds as libc::time_t;
        unsafe {
            libc::localtime_r(&value, &mut tm);
        }
        (
            rtc::Date {
                years_since_2000: (tm.tm_year - 100).clamp(0, 99) as u8,
                month: (tm.tm_mon + 1) as u8,
                day: tm.tm_mday as u8,
                days_from_sunday: tm.tm_wday as u8,
            },
            rtc::Time {
                hour: tm.tm_hour as u8,
                minute: tm.tm_min as u8,
                second: tm.tm_sec as u8,
            },
        )
    }
}
impl rtc::Backend for Clock {
    fn as_any(&self) -> &dyn std::any::Any {
        self
    }
    fn as_any_mut(&mut self) -> &mut dyn std::any::Any {
        self
    }
    fn get_time(&mut self) -> rtc::Time {
        self.now().1
    }
    fn get_date_time(&mut self) -> (rtc::Date, rtc::Time) {
        self.now()
    }
    fn set_date_time(&mut self, value: (rtc::Date, rtc::Time)) {
        let (d, t) = value;
        let mut tm: libc::tm = unsafe { std::mem::zeroed() };
        tm.tm_year = d.years_since_2000 as i32 + 100;
        tm.tm_mon = d.month as i32 - 1;
        tm.tm_mday = d.day as i32;
        tm.tm_hour = t.hour as i32;
        tm.tm_min = t.minute as i32;
        tm.tm_sec = t.second as i32;
        tm.tm_isdst = -1;
        let stamp = unsafe { libc::mktime(&mut tm) } as i64;
        let host = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap_or_default()
            .as_secs() as i64;
        self.offset = stamp - host;
    }
}
struct Sound {
    pcm: Vec<i16>,
}
impl audio::Backend for Sound {
    fn handle_sample_chunk(&mut self, samples: &mut Vec<[audio::OutputSample; 2]>) {
        self.pcm.clear();
        let pcm = &mut self.pcm;
        for s in samples.iter() {
            for v in s {
                pcm.push(pcm_sample(*v));
            }
        }
        unsafe {
            if let Some(cb) = AUDIO {
                cb(pcm.as_ptr(), samples.len());
            }
        }
        samples.clear();
    }
}
struct Core {
    emu: emu::Emu<Interpreter>,
    device: Arc<wgpu::Device>,
    queue: Arc<wgpu::Queue>,
    channels: dust_wgpu_2d::threaded::lockstep_scanlines::FrontendChannels,
    channels3: dust_wgpu_3d::threaded::FrontendChannels,
    buffer: wgpu::Buffer,
    pixels: Vec<u32>,
    scale: u8,
    output_scale: u8,
    frame: u64,
    rate: u32,
    save: PathBuf,
}
fn buffer(device: &wgpu::Device, s: u8) -> wgpu::Buffer {
    device.create_buffer(&wgpu::BufferDescriptor {
        label: Some("Dust frontend readback"),
        size: (256u64 * u64::from(s)) * (384u64 * u64::from(s)) * 4,
        usage: wgpu::BufferUsages::COPY_DST | wgpu::BufferUsages::MAP_READ,
        mapped_at_creation: false,
    })
}
fn save_device(rom: &[u8], path: &PathBuf) -> Result<ds_slot::spi::Spi, String> {
    if rom.len() < 0x200 {
        return Err("ROM header is truncated".into());
    }
    let code = u32::from_le_bytes(rom[12..16].try_into().unwrap());
    let db: serde_json::Value =
        serde_json::from_str(include_str!(concat!(env!("DUST_SOURCE"), "/game_db.json")))
            .map_err(|e| e.to_string())?;
    let kind = db
        .as_array()
        .unwrap()
        .iter()
        .find(|v| v["code"].as_u64() == Some(code as u64))
        .and_then(|v| v["save-type"].as_str())
        .ok_or("Cartridge is absent from the Dust save database; use another DS core")?;
    let len = match kind {
        "none" => 0,
        "eeprom-4k" => 0x200,
        "eeprom-fram-64k" => 0x2000,
        "eeprom-fram-512k" => 0x10000,
        "eeprom-fram-1m" => 0x20000,
        "flash-2m" => 0x40000,
        "flash-4m" => 0x80000,
        "flash-8m" => 0x100000,
        _ => return Err(format!("Unsupported Dust cartridge save type: {kind}")),
    };
    let contents = match std::fs::read(path) {
        Ok(bytes) => {
            if bytes.len() != len {
                return Err("Dust save length does not match cartridge database".into());
            }
            let mut b = BoxedByteSlice::new_zeroed(len);
            b.copy_from_slice(&bytes);
            SaveContents::Existing(b)
        }
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => SaveContents::New(len),
        Err(e) => return Err(e.to_string()),
    };
    Ok(match kind {
        "none" => ds_slot::spi::Empty::new().into(),
        "eeprom-4k" => ds_slot::spi::eeprom_4k::Eeprom4k::new(contents, None)
            .map_err(|_| "EEPROM size")?
            .into(),
        "eeprom-fram-64k" | "eeprom-fram-512k" | "eeprom-fram-1m" => {
            ds_slot::spi::eeprom_fram::EepromFram::new(contents, None)
                .map_err(|_| "EEPROM size")?
                .into()
        }
        _ => ds_slot::spi::flash::Flash::new(contents, [0; 20], rom[12] == b'I')
            .map_err(|_| "Flash size")?
            .into(),
    })
}
impl Core {
    async unsafe fn new(rom: Vec<u8>, path: PathBuf, s: u8) -> Result<Self, String> {
        let instance = wgpu::Instance::new(wgpu::InstanceDescriptor {
            backends: wgpu::Backends::METAL,
            ..Default::default()
        });
        let adapter = instance
            .request_adapter(&wgpu::RequestAdapterOptions::default())
            .await
            .ok_or("Metal GPU unavailable")?;
        println!("Dust GPU core: {:?}", adapter.get_info());
        let (d, q) = adapter
            .request_device(
                &wgpu::DeviceDescriptor {
                    label: None,
                    required_features: wgpu::Features::empty(),
                    required_limits: wgpu::Limits {
                        max_texture_dimension_2d: 4096,
                        max_bind_groups: 5,
                        ..wgpu::Limits::downlevel_webgl2_defaults()
                    },
                    memory_hints: wgpu::MemoryHints::MemoryUsage,
                },
                None,
            )
            .await
            .map_err(|e| e.to_string())?;
        let device = Arc::new(d);
        let queue = Arc::new(q);
        std::env::set_var("DSTV_DUST_PIPELINES", path.with_file_name("pipelines-dstv-v1.cache"));
        let (tx, rx, channels3, data) =
            dust_wgpu_3d::threaded::init(device.clone(), queue.clone(), s);
        let rx3 = dust_wgpu_2d::Renderer3dRx::Accel {
            rx: Box::new(rx),
            color_output_view: data.color_output_view,
            color_output_view_rx: data.color_output_view_rx,
            last_submitted_frame: data.last_submitted_frame,
        };
        let out_s = output_scale(s);
        let (renderer, _, channels) = dust_wgpu_2d::threaded::lockstep_scanlines::Renderer::new(
            device.clone(),
            queue.clone(),
            out_s,
            rx3,
        );
        let spi = save_device(&rom, &path)?;
        let mut bytes = BoxedByteSlice::new_zeroed(rom.len());
        bytes.copy_from_slice(&rom);
        let fw = Flash::new(
            SaveContents::Existing(firmware::default(Model::Ds)),
            firmware::id_for_model(Model::Ds),
        )
        .map_err(|_| "firmware")?;
        let mut builder = emu::Builder::new(
            fw,
            Some(Box::new(bytes)),
            spi,
            Box::new(Sound {
                pcm: Vec::with_capacity(512),
            }),
            None,
            Box::new(Clock { offset: 0 }),
            Box::new(renderer),
            Box::new(tx),
            None,
        );
        builder.audio_sample_chunk_size = 256;
        let emu = builder
            .build(Interpreter)
            .map_err(|_| "Dust core initialization")?;
        let readback = buffer(&device, out_s);
        Ok(Self {
            emu,
            device,
            queue,
            channels,
            channels3,
            buffer: readback,
            pixels: Vec::new(),
            scale: s,
            output_scale: out_s,
            frame: 0,
            rate: output_rate(),
            save: path,
        })
    }
    fn flush(&mut self) {
        let spi = &mut self.emu.ds_slot.spi;
        if !spi.contents_dirty() {
            return;
        }
        let temp = self.save.with_extension("sav.tmp");
        let result =
            std::fs::write(&temp, spi.contents()).and_then(|_| std::fs::rename(&temp, &self.save));
        match result {
            Ok(()) => spi.mark_contents_flushed(),
            Err(e) => eprintln!("Dust save failed: {e}"),
        }
    }
    unsafe fn run(&mut self) {
        if let Some(p) = POLL {
            p();
        }
        if let Some(input) = INPUT {
            let ids = [8, 0, 2, 3, 7, 6, 4, 5, 11, 10, 9, 1];
            let keys = [
                Keys::A,
                Keys::B,
                Keys::SELECT,
                Keys::START,
                Keys::RIGHT,
                Keys::LEFT,
                Keys::UP,
                Keys::DOWN,
                Keys::R,
                Keys::L,
                Keys::X,
                Keys::Y,
            ];
            let mut held = Keys::empty();
            for (id, key) in ids.into_iter().zip(keys) {
                if input(0, 1, 0, id) != 0 {
                    held |= key;
                }
            }
            self.emu.release_keys(Keys::all() & !held);
            self.emu.press_keys(held);
            if input(0, 6, 0, 2) != 0 {
                let x = touch_axis(input(0, 6, 0, 0), 4096);
                let y = touch_axis(input(0, 6, 0, 1), 3072);
                self.emu.set_touch_pos([x, y]);
            } else {
                self.emu.end_touch();
            }
        }
        let s = scale();
        self.rate = output_rate();
        let out_s = output_scale(s);
        if s != self.scale || out_s != self.output_scale {
            self.channels3.set_resolution_scale_factor(s);
            self.channels.set_resolution_scale_factor(out_s);
            self.scale = s;
            self.output_scale = out_s;
            self.buffer = buffer(&self.device, out_s);
            let mut av = av(out_s);
            if let Some(e) = ENV {
                e(37, (&mut av.geometry as *mut Geometry).cast());
            }
        }
        if !matches!(self.emu.run(), emu::RunOutput::FrameFinished) {
            return;
        }
        self.frame += 1;
        let wait = Instant::now();
        while self.channels.submitted_frame() < self.frame {
            if wait.elapsed() > Duration::from_secs(5) {
                eprintln!("Dust GPU stalled");
                return;
            }
            std::thread::yield_now();
        }
        if self.frame % 120 == 0 {
            self.flush();
        }
        if self.rate == 30 && self.frame % 2 == 0 {
            return;
        }
        let w = 256u32 * u32::from(self.output_scale);
        let h = 384u32 * u32::from(self.output_scale);
        let Some(texture) = self.channels.output_texture() else {
            return;
        };
        let mut enc = self.device.create_command_encoder(&Default::default());
        enc.copy_texture_to_buffer(
            wgpu::ImageCopyTexture {
                texture: &texture,
                mip_level: 0,
                origin: wgpu::Origin3d::ZERO,
                aspect: wgpu::TextureAspect::All,
            },
            wgpu::ImageCopyBuffer {
                buffer: &self.buffer,
                layout: wgpu::ImageDataLayout {
                    offset: 0,
                    bytes_per_row: Some(w * 4),
                    rows_per_image: Some(h),
                },
            },
            wgpu::Extent3d {
                width: w,
                height: h,
                depth_or_array_layers: 1,
            },
        );
        self.queue.submit([enc.finish()]);
        let slice = self.buffer.slice(..);
        let (tx, rx) = std::sync::mpsc::channel();
        slice.map_async(wgpu::MapMode::Read, move |r| {
            let _ = tx.send(r);
        });
        self.device.poll(wgpu::Maintain::Wait);
        if !matches!(rx.recv(), Ok(Ok(()))) {
            return;
        }
        {
            let data = slice.get_mapped_range();
            self.pixels.resize((w * h) as usize, 0);
            for (dst, src) in self.pixels.iter_mut().zip(data.chunks_exact(4)) {
                *dst = u32::from_le_bytes([src[2], src[1], src[0], 255]);
            }
        }
        self.buffer.unmap();
        if let Some(v) = VIDEO {
            v(self.pixels.as_ptr().cast(), w, h, (w * 4) as usize);
        }
    }
}
fn av(s: u8) -> Av {
    Av {
        geometry: Geometry {
            width: 256 * u32::from(s),
            height: 384 * u32::from(s),
            max_width: 2048,
            max_height: 3072,
            aspect: 2.0 / 3.0,
        },
        timing: Timing {
            fps: 33554432.0 / (6.0 * 355.0 * 263.0),
            sample_rate: 32768.0,
        },
    }
}
#[no_mangle]
pub unsafe extern "C" fn retro_set_environment(v: Env) {
    ENV = Some(v);
}
#[no_mangle]
pub unsafe extern "C" fn retro_set_video_refresh(v: Video) {
    VIDEO = Some(v);
}
#[no_mangle]
pub unsafe extern "C" fn retro_set_audio_sample_batch(v: Audio) {
    AUDIO = Some(v);
}
#[no_mangle]
pub extern "C" fn retro_set_audio_sample(_: unsafe extern "C" fn(i16, i16)) {}
#[no_mangle]
pub unsafe extern "C" fn retro_set_input_poll(v: unsafe extern "C" fn()) {
    POLL = Some(v);
}
#[no_mangle]
pub unsafe extern "C" fn retro_set_input_state(v: Input) {
    INPUT = Some(v);
}
#[no_mangle]
pub extern "C" fn retro_api_version() -> u32 {
    1
}
#[no_mangle]
pub extern "C" fn retro_init() {}
#[no_mangle]
pub unsafe extern "C" fn retro_deinit() {
    retro_unload_game();
}
#[no_mangle]
pub unsafe extern "C" fn retro_get_system_info(i: *mut Info) {
    *i = Info {
        name: c"Dust Metal (Experimental)".as_ptr(),
        version: c"0.1-dstv".as_ptr(),
        extensions: c"nds".as_ptr(),
        fullpath: false,
        block_extract: false,
    };
}
#[no_mangle]
pub unsafe extern "C" fn retro_get_system_av_info(i: *mut Av) {
    *i = av(output_scale(scale()));
}
#[no_mangle]
pub unsafe extern "C" fn retro_load_game(g: *const Game) -> bool {
    retro_unload_game();
    if g.is_null() {
        return false;
    }
    let g = &*g;
    if g.data.is_null() || g.size < 0x200 || g.size > 1024 * 1024 * 1024 {
        return false;
    }
    let mut format = 1u32;
    if !ENV
        .map(|e| e(10, (&mut format as *mut u32).cast()))
        .unwrap_or(false)
    {
        return false;
    }
    let mut dir: *const c_char = std::ptr::null();
    if !ENV
        .map(|e| e(31, (&mut dir as *mut *const c_char).cast()))
        .unwrap_or(false)
        || dir.is_null()
    {
        return false;
    }
    let folder = PathBuf::from(CStr::from_ptr(dir).to_string_lossy().as_ref());
    if let Err(e) = std::fs::create_dir_all(&folder) {
        eprintln!("Dust save directory: {e}");
        return false;
    }
    ROM_PATH = if g.path.is_null() {
        None
    } else {
        Some(PathBuf::from(
            CStr::from_ptr(g.path).to_string_lossy().as_ref(),
        ))
    };
    let rom = std::slice::from_raw_parts(g.data.cast::<u8>(), g.size).to_vec();
    match pollster::block_on(Core::new(rom, folder.join("cartridge.sav"), scale())) {
        Ok(c) => {
            CORE = Some(c);
            true
        }
        Err(e) => {
            eprintln!("Dust load failed: {e}");
            false
        }
    }
}
#[no_mangle]
pub unsafe extern "C" fn retro_unload_game() {
    if let Some(mut c) = CORE.take() {
        c.flush();
        c.device.poll(wgpu::Maintain::Wait);
        drop(c);
    }
}
#[no_mangle]
pub unsafe extern "C" fn retro_run() {
    if let Some(c) = CORE.as_mut() {
        c.run();
    }
}
#[no_mangle]
pub unsafe extern "C" fn retro_reset() {
    let Some(path) = ROM_PATH.clone() else {
        return;
    };
    let Some(mut old) = CORE.take() else {
        return;
    };
    old.flush();
    let save = old.save.clone();
    drop(old);
    match std::fs::read(path)
        .map_err(|e| e.to_string())
        .and_then(|rom| pollster::block_on(Core::new(rom, save, scale())))
    {
        Ok(c) => CORE = Some(c),
        Err(e) => eprintln!("Dust reset failed: {e}"),
    }
}
#[no_mangle]
pub extern "C" fn retro_serialize_size() -> usize {
    0
}
#[no_mangle]
pub extern "C" fn retro_serialize(_: *mut c_void, _: usize) -> bool {
    false
}
#[no_mangle]
pub extern "C" fn retro_unserialize(_: *const c_void, _: usize) -> bool {
    false
}
#[no_mangle]
pub extern "C" fn retro_get_memory_data(_: u32) -> *mut c_void {
    std::ptr::null_mut()
}
#[no_mangle]
pub extern "C" fn retro_get_memory_size(_: u32) -> usize {
    0
}
#[no_mangle]
pub extern "C" fn retro_get_region() -> u32 {
    0
}
#[no_mangle]
pub extern "C" fn retro_set_controller_port_device(_: u32, _: u32) {}
#[no_mangle]
pub extern "C" fn retro_cheat_reset() {}
#[no_mangle]
pub extern "C" fn retro_cheat_set(_: u32, _: bool, _: *const c_char) {}
#[no_mangle]
pub extern "C" fn retro_load_game_special(_: u32, _: *const Game, _: usize) -> bool {
    false
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn native_timing_and_conversion() {
        assert!((av(2).timing.fps - 59.8983059319).abs() < 0.000001);
        assert_eq!(pcm_sample(0), -32768);
        assert_eq!(pcm_sample(512), 0);
        assert_eq!(pcm_sample(1023), 32704);
        assert_eq!(touch_axis(-32767, 4096), 0);
        assert_eq!(touch_axis(0, 4096), 2048);
        assert_eq!(touch_axis(32767, 4096), 4095);
        assert_eq!(touch_axis(0, 3072), 1536);
        assert_eq!(touch_axis(32767, 3072), 3071);
        for (f, s) in [
            (0, 1), (1, 1), (2, 2), (3, 3), (4, 4),
            (5, 5), (6, 6), (7, 7), (8, 8), (99, 8),
        ] {
            assert_eq!(sanitize_scale(f), s);
        }
    }
    #[test]
    fn cartridge_database_and_save_reload() {
        let folder =
            std::env::temp_dir().join(format!("dstv-dust-save-test-{}", std::process::id()));
        std::fs::create_dir_all(&folder).unwrap();
        let path = folder.join("cartridge.sav");
        let _ = std::fs::remove_file(&path);
        let mut rom = vec![0u8; 0x200];
        rom[12..16].copy_from_slice(b"IRBO");
        let mut spi = save_device(&rom, &path).unwrap();
        assert_eq!(spi.contents().len(), 0x80000);
        spi.contents_mut()[123] = 42;
        std::fs::write(&path, spi.contents()).unwrap();
        assert_eq!(save_device(&rom, &path).unwrap().contents()[123], 42);
        std::fs::write(&path, [0; 32]).unwrap();
        assert!(save_device(&rom, &path).is_err());
        assert!(save_device(&rom[..16], &path).is_err());
        std::fs::remove_dir_all(folder).unwrap();
    }
}

#[no_mangle]
pub unsafe extern "C" fn dstv_dust_internal_scale() -> u32 {
    CORE.as_ref().map(|c| u32::from(c.scale)).unwrap_or(1)
}

#[no_mangle] pub extern "C" fn dstv_dust_gpu_frame_count()->u64 { dust_wgpu_3d::threaded::GPU_SUBMITTED_FRAMES.load(std::sync::atomic::Ordering::Relaxed) }
