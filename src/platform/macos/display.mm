/**
 * @file src/platform/macos/display.mm
 * @brief Definitions for display capture on macOS.
 */

// standard includes
#include <charconv>
#include <chrono>
#include <optional>
#include <string_view>

// local includes
#include "src/config.h"
#include "src/display_device.h"
#include "src/logging.h"
#include "src/platform/common.h"
#include "src/platform/macos/av_img_t.h"
#include "src/platform/macos/av_video.h"
#include "src/platform/macos/misc.h"
#include "src/platform/macos/nv12_zero_device.h"

// Avoid conflict between AVFoundation and libavutil both defining AVMediaType
/**
 * @def AVMediaType
 * @brief Macro for AV media type.
 */
#define AVMediaType AVMediaType_FFmpeg
#include "src/video.h"
#undef AVMediaType

namespace platf {
  using namespace std::literals;

  namespace {
    constexpr std::string_view kCameraPrefix = "camera:"sv;

    bool is_camera_name(std::string_view display_name) {
      return display_name.rfind(kCameraPrefix, 0) == 0;
    }

    struct camera_info_t {
      std::string unique_id;  ///< AVCaptureDevice.uniqueID.
      std::string name;  ///< Human-readable camera name.
    };

    // Camera access is a separate TCC permission from screen recording, and
    // unlike screen recording (see platf::init() in misc.mm, which requests
    // it unconditionally at every Sunshine startup) it's requested lazily,
    // only once a client actually picks a "camera:" output_name — most
    // Sunshine users never touch a camera and shouldn't see that prompt.
    // AVCaptureDeviceDiscoverySession silently returns zero devices when
    // this process isn't authorized yet, which is otherwise indistinguishable
    // from "no camera plugged in" — request/await it explicitly so the
    // caller gets real devices (or a clear denial) instead of an empty list.
    bool ensure_camera_access() {
      AVAuthorizationStatus status = [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeVideo];
      if (status == AVAuthorizationStatusNotDetermined) {
        dispatch_semaphore_t sem = dispatch_semaphore_create(0);
        [AVCaptureDevice requestAccessForMediaType:AVMediaTypeVideo completionHandler:^(BOOL granted) {
          dispatch_semaphore_signal(sem);
        }];
        dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);
        status = [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeVideo];
      }
      if (status != AVAuthorizationStatusAuthorized) {
        BOOST_LOG(error) << "No camera permission!"sv;
        BOOST_LOG(error) << "Please activate it in 'System Settings' -> 'Privacy & Security' -> 'Camera'"sv;
        return false;
      }
      return true;
    }

    std::vector<camera_info_t> enumerate_camera_devices() {
      std::vector<camera_info_t> result;
      if (!ensure_camera_access()) {
        return result;
      }

      NSMutableArray<AVCaptureDeviceType> *deviceTypes = [NSMutableArray arrayWithObject:AVCaptureDeviceTypeBuiltInWideAngleCamera];
      if (@available(macOS 14.0, *)) {
        [deviceTypes addObject:AVCaptureDeviceTypeExternal];
      }

      AVCaptureDeviceDiscoverySession *discovery =
        [AVCaptureDeviceDiscoverySession discoverySessionWithDeviceTypes:deviceTypes
                                                                mediaType:AVMediaTypeVideo
                                                                 position:AVCaptureDevicePositionUnspecified];

      for (AVCaptureDevice *device in discovery.devices) {
        camera_info_t info;
        info.unique_id = [device.uniqueID UTF8String];
        info.name = [device.localizedName UTF8String];
        result.push_back(std::move(info));
      }

      return result;
    }

    // Cache of already-open camera AVVideo sessions, keyed by
    // AVCaptureDevice.uniqueID. probe_encoders() (video.cpp) calls
    // platf::display() once per candidate codec (h264/hevc/av1), tearing down
    // and reconstructing a brand new AVCaptureSession/AVCaptureDeviceInput
    // for the *same physical camera* each time. The built-in FaceTime camera
    // (macOS's own DAL-backed ISP) tolerates this rapid session churn fine,
    // but many external USB/UVC capture devices are exclusive-access and
    // don't reliably resume delivering frames when re-claimed in quick
    // succession -- observed as probe_encoders() looping forever ("Testing
    // for available encoders...") without ever settling, no explicit error.
    // Reusing the same running AVCaptureSession across those calls (an extra
    // retained reference here keeps it alive even as each av_display_t's own
    // reference is released) avoids the repeated claim/release entirely.
    NSMutableDictionary<NSString *, AVVideo *> *camera_session_cache() {
      static NSMutableDictionary<NSString *, AVVideo *> *cache = [[NSMutableDictionary alloc] init];
      return cache;
    }

    std::optional<CGDirectDisplayID> parse_display_id(std::string_view display_name) {
      if (display_name.empty()) {
        return std::nullopt;
      }

      CGDirectDisplayID display_id {};
      const auto *const begin {display_name.data()};
      const auto *const end {display_name.data() + display_name.size()};
      const auto [ptr, ec] {std::from_chars(begin, end, display_id)};
      if (ec != std::errc {} || ptr != end) {
        return std::nullopt;
      }

      return display_id;
    }

    OSType videotoolbox_pixel_format(const video::config_t &config) {
      const auto colorspace {video::colorspace_from_client_config(config, false)};
      return colorspace.bit_depth == 10 ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange;
    }
  }  // namespace

  /**
   * @brief macOS display capture source and image buffers.
   */
  struct av_display_t: public display_t {
    AVVideo *av_capture {};  ///< AV capture.
    CGDirectDisplayID display_id {};  ///< Display ID.
    std::unique_ptr<display_device::DisplayPowerGuardInterface> display_power_guard;  ///< Display power guard.

    ~av_display_t() override {
      [av_capture release];
    }

    capture_e capture(const push_captured_image_cb_t &push_captured_image_cb, const pull_free_image_cb_t &pull_free_image_cb, bool *cursor) override {
      auto signal = [av_capture capture:^(CMSampleBufferRef sampleBuffer) {
        auto new_sample_buffer = std::make_shared<av_sample_buf_t>(sampleBuffer);
        auto new_pixel_buffer = std::make_shared<av_pixel_buf_t>(new_sample_buffer->buf);

        std::shared_ptr<img_t> img_out;
        if (!pull_free_image_cb(img_out)) {
          // got interrupt signal
          // returning false here stops capture backend
          return false;
        }
        auto av_img = std::static_pointer_cast<av_img_t>(img_out);

        auto old_data_retainer = std::make_shared<temp_retain_av_img_t>(
          av_img->sample_buffer,
          av_img->pixel_buffer,
          img_out->data
        );

        av_img->sample_buffer = new_sample_buffer;
        av_img->pixel_buffer = new_pixel_buffer;
        img_out->data = new_pixel_buffer->data();

        img_out->width = (int) CVPixelBufferGetWidth(new_pixel_buffer->buf);
        img_out->height = (int) CVPixelBufferGetHeight(new_pixel_buffer->buf);
        img_out->row_pitch = (int) CVPixelBufferGetBytesPerRow(new_pixel_buffer->buf);
        img_out->pixel_pitch = img_out->row_pitch / img_out->width;

        old_data_retainer = nullptr;

        if (!push_captured_image_cb(std::move(img_out), true)) {
          // got interrupt signal
          // returning false here stops capture backend
          return false;
        }

        return true;
      }];

      // FIXME: We should time out if an image isn't returned for a while
      dispatch_semaphore_wait(signal, DISPATCH_TIME_FOREVER);

      return capture_e::ok;
    }

    /**
     * @brief Allocate an image buffer compatible with this display backend.
     *
     * @return Allocated img object, or null when unavailable.
     */
    std::shared_ptr<img_t> alloc_img() override {
      return std::make_shared<av_img_t>();
    }

    /**
     * @brief Create AVCodec encode device.
     *
     * @param pix_fmt Sunshine pixel format to convert or allocate for.
     * @return Constructed AVCodec encode device object.
     */
    std::unique_ptr<avcodec_encode_device_t> make_avcodec_encode_device(pix_fmt_e pix_fmt) override {
      if (pix_fmt == pix_fmt_e::yuv420p) {
        av_capture.pixelFormat = kCVPixelFormatType_32BGRA;

        return std::make_unique<avcodec_encode_device_t>();
      } else if (pix_fmt == pix_fmt_e::nv12 || pix_fmt == pix_fmt_e::p010) {
        auto device = std::make_unique<nv12_zero_device>();

        device->init(static_cast<void *>(av_capture), pix_fmt, setResolution, setPixelFormat);

        return device;
      } else {
        BOOST_LOG(error) << "Unsupported Pixel Format."sv;
        return nullptr;
      }
    }

    /**
     * @brief Populate a fallback image when real capture data is unavailable.
     *
     * @param img Image or frame object to read from or populate.
     * @return Capture status reported to the streaming pipeline.
     */
    int dummy_img(img_t *img) override {
      if (!platf::is_screen_capture_allowed()) {
        // If we don't have the screen capture permission, this function will hang
        // indefinitely without doing anything useful. Exit instead to avoid this.
        // A non-zero return value indicates failure to the calling function.
        return 1;
      }

      auto signal = [av_capture capture:^(CMSampleBufferRef sampleBuffer) {
        auto new_sample_buffer = std::make_shared<av_sample_buf_t>(sampleBuffer);
        auto new_pixel_buffer = std::make_shared<av_pixel_buf_t>(new_sample_buffer->buf);

        auto av_img = (av_img_t *) img;

        auto old_data_retainer = std::make_shared<temp_retain_av_img_t>(
          av_img->sample_buffer,
          av_img->pixel_buffer,
          img->data
        );

        av_img->sample_buffer = new_sample_buffer;
        av_img->pixel_buffer = new_pixel_buffer;
        img->data = new_pixel_buffer->data();

        img->width = (int) CVPixelBufferGetWidth(new_pixel_buffer->buf);
        img->height = (int) CVPixelBufferGetHeight(new_pixel_buffer->buf);
        img->row_pitch = (int) CVPixelBufferGetBytesPerRow(new_pixel_buffer->buf);
        img->pixel_pitch = img->row_pitch / img->width;

        old_data_retainer = nullptr;

        // returning false here stops capture backend
        return false;
      }];

      dispatch_semaphore_wait(signal, DISPATCH_TIME_FOREVER);

      return 0;
    }

    /**
     * A bridge from the pure C++ code of the hwdevice_t class to the pure Objective C code.
     *
     * display --> an opaque pointer to an object of this class
     * width --> the intended capture width
     * height --> the intended capture height
     * @param display Display object or identifier associated with the operation.
     * @param width Frame or display width in pixels.
     * @param height Frame or display height in pixels.
     */
    static void setResolution(void *display, int width, int height) {
      [static_cast<AVVideo *>(display) setFrameWidth:width frameHeight:height];
    }

    /**
     * @brief Set pixel format.
     *
     * @param display Display object or identifier associated with the operation.
     * @param pixelFormat Pixel format.
     */
    static void setPixelFormat(void *display, OSType pixelFormat) {
      static_cast<AVVideo *>(display).pixelFormat = pixelFormat;
    }
  };

  std::shared_ptr<display_t> display(platf::mem_type_e hwdevice_type, const std::string &display_name, const video::config_t &config) {
    if (hwdevice_type != platf::mem_type_e::system && hwdevice_type != platf::mem_type_e::videotoolbox) {
      BOOST_LOG(error) << "Could not initialize display with the given hw device type."sv;
      return nullptr;
    }

    auto display = std::make_shared<av_display_t>();

    if (is_camera_name(display_name)) {
      if (!ensure_camera_access()) {
        return nullptr;
      }

      std::string unique_id {display_name.substr(kCameraPrefix.size())};

      NSString *ns_unique_id = [NSString stringWithUTF8String:unique_id.c_str()];
      NSMutableDictionary<NSString *, AVVideo *> *cache = camera_session_cache();

      @synchronized(cache) {
        AVVideo *cached = [cache objectForKey:ns_unique_id];
        if (cached) {
          BOOST_LOG(info) << "Reusing already-open camera session ("sv << unique_id << ") to stream"sv;
          // objectForKey: doesn't transfer ownership -- the dictionary keeps
          // its own +1. av_display_t::~av_display_t() unconditionally
          // releases av_capture, so this av_display_t needs its own +1 to
          // balance that (matching the +1 that initWithCameraUniqueID: below
          // gives the not-cached branch, which is what normally gets
          // balanced by that same release).
          display->av_capture = [cached retain];
        } else {
          BOOST_LOG(info) << "Configuring selected camera ("sv << unique_id << ") to stream"sv;
          display->av_capture = [[AVVideo alloc] initWithCameraUniqueID:ns_unique_id frameRate:config.framerate];
          if (display->av_capture) {
            // setObject:forKey: retains its own +1, kept alive across this
            // av_display_t's lifetime (and released by ~av_display_t()) so
            // the next probe/reconnect attempt can reuse the same session
            // instead of re-claiming the physical device from scratch.
            [cache setObject:display->av_capture forKey:ns_unique_id];
          }
        }
      }

      if (!display->av_capture) {
        BOOST_LOG(error) << "Camera setup failed (not found, in use, or permission denied)."sv;
        return nullptr;
      }

      // Switch the camera to whichever of its own real AVCaptureDeviceFormats
      // best matches what the client actually asked for, instead of just
      // resizing/upscaling whatever format macOS defaulted the device to
      // (e.g. a 720p default format stretched to a requested 1080p stream,
      // which looks soft even though the physical sensor may support real
      // 1080p+ in one of its other formats). No-op the first time a cached
      // session is reused at the same size it's already running at.
      [display->av_capture selectBestFormatForWidth:config.width height:config.height frameRate:config.framerate];

      display->width = display->av_capture.frameWidth;
      display->height = display->av_capture.frameHeight;
      display->env_width = display->width;
      display->env_height = display->height;

      if (hwdevice_type == platf::mem_type_e::videotoolbox) {
        const auto pixel_format {videotoolbox_pixel_format(config)};
        [display->av_capture setFrameWidth:config.width frameHeight:config.height];
        display->av_capture.pixelFormat = pixel_format;
      }

      return display;
    }

    BOOST_LOG(debug) << "Waking display for capture selector ["sv << display_name << ']';
    if (!display_device::wake_display(display_name, 1s)) {
      BOOST_LOG(debug) << "Display wake attempt did not expose the requested display ["sv << display_name << ']';
    }

    display->display_power_guard = display_device::keep_display_awake("Sunshine display capture");
    if (display->display_power_guard) {
      BOOST_LOG(debug) << "Keeping display awake for capture"sv;
    } else {
      BOOST_LOG(debug) << "Unable to create display sleep prevention assertion"sv;
    }

    // Default to main display
    display->display_id = CGMainDisplayID();

    if (const auto configured_display_id {parse_display_id(display_name)}) {
      display->display_id = *configured_display_id;
    } else if (!display_name.empty()) {
      BOOST_LOG(warning) << "Configured display ["sv << display_name
                         << "] is not a valid macOS capture display id. Falling back to main display ["sv
                         << display->display_id << "]."sv;
    }

    // Print all displays available with their names and ids
    BOOST_LOG(debug) << "Detecting displays"sv;
    for (const auto &device : display_device::enumerate_devices()) {
      if (device.m_display_name.empty()) {
        continue;
      }

      BOOST_LOG(debug) << "Detected display: "sv << device.m_friendly_name
                       << " (id: "sv << device.m_display_name << ") connected: true"sv;
    }

    BOOST_LOG(info) << "Configuring selected display ("sv << display->display_id << ") to stream"sv;

    display->av_capture = [[AVVideo alloc] initWithDisplay:display->display_id frameRate:config.framerate];

    if (!display->av_capture) {
      BOOST_LOG(error) << "Video setup failed."sv;
      return nullptr;
    }

    display->width = display->av_capture.frameWidth;
    display->height = display->av_capture.frameHeight;
    // We also need set env_width and env_height for absolute mouse coordinates
    display->env_width = display->width;
    display->env_height = display->height;

    if (hwdevice_type == platf::mem_type_e::videotoolbox) {
      const auto pixel_format {videotoolbox_pixel_format(config)};
      [display->av_capture setFrameWidth:config.width frameHeight:config.height];
      display->av_capture.pixelFormat = pixel_format;
    }

    return display;
  }

  std::vector<std::string> display_names(mem_type_e hwdevice_type) {
    std::vector<std::string> display_names;
    if (hwdevice_type != platf::mem_type_e::system && hwdevice_type != platf::mem_type_e::videotoolbox) {
      return display_names;
    }

    const auto devices {display_device::enumerate_devices()};
    display_names.reserve(devices.size());
    for (const auto &device : devices) {
      if (!device.m_display_name.empty()) {
        display_names.emplace_back(device.m_display_name);
      }
    }

    for (const auto &camera : enumerate_camera_devices()) {
      display_names.emplace_back(std::string(kCameraPrefix) + camera.unique_id);
    }

    return display_names;
  }

  /**
   * @brief Report whether encoder backends should be probed again before streaming.
   *
   * @return Always `true` because macOS GPU changes are not tracked by this backend.
   */
  bool needs_encoder_reenumeration() {
    // We don't track GPU state, so we will always reenumerate. Fortunately, it is fast on macOS.
    return true;
  }
}  // namespace platf
