#import <AVFoundation/AVFoundation.h>
#import <Cocoa/Cocoa.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <ImageIO/ImageIO.h>

#include "libobsensor/ObSensor.hpp"
#include "libobsensor/hpp/Error.hpp"

#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <fstream>
#include <iomanip>
#include <memory>
#include <mutex>
#include <sstream>
#include <string>
#include <thread>
#include <vector>

namespace {

struct CloudPoint {
    float   x;
    float   y;
    float   z;
    uint8_t r;
    uint8_t g;
    uint8_t b;
};

static NSString *NSStringFromStd(const std::string &value) {
    return [NSString stringWithUTF8String:value.c_str()] ?: @"";
}

static std::string StdString(NSString *value) {
    return value ? std::string([value UTF8String]) : std::string();
}

static NSString *AppRootPath() {
    NSString *envRoot = [[[NSProcessInfo processInfo] environment] objectForKey:@"ORBBEC_TEST_ROOT"];
    if(envRoot.length > 0) {
        return envRoot;
    }

    NSString *exePath = [[NSBundle mainBundle] executablePath];
    NSString *dir     = [exePath stringByDeletingLastPathComponent];
    for(int i = 0; i < 4; ++i) {
        dir = [dir stringByDeletingLastPathComponent];
    }
    if([[dir lastPathComponent] isEqualToString:@"OrbbecTest"]) {
        return dir;
    }
    return [[NSFileManager defaultManager] currentDirectoryPath];
}

static NSString *CaptureDirectory() {
    NSString *dir = [AppRootPath() stringByAppendingPathComponent:@"outputs/viewer_captures"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    return dir;
}

static NSString *Timestamp() {
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    formatter.locale     = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    formatter.dateFormat = @"yyyyMMdd_HHmmss";
    return [formatter stringFromDate:[NSDate date]];
}

static std::string SDKErrorString(const ob::Error &e) {
    return std::string(e.getName()) + "(" + e.getArgs() + "): " + e.getMessage() + " type="
           + std::to_string(static_cast<int>(e.getExceptionType()));
}

static std::string SensorName(OBSensorType type) {
    switch(type) {
    case OB_SENSOR_IR:
        return "IR";
    case OB_SENSOR_COLOR:
        return "COLOR";
    case OB_SENSOR_DEPTH:
        return "DEPTH";
    case OB_SENSOR_ACCEL:
        return "ACCEL";
    case OB_SENSOR_GYRO:
        return "GYRO";
    case OB_SENSOR_IR_LEFT:
        return "IR_LEFT";
    case OB_SENSOR_IR_RIGHT:
        return "IR_RIGHT";
    case OB_SENSOR_RAW_PHASE:
        return "RAW_PHASE";
    default:
        return "UNKNOWN";
    }
}

static std::string StreamName(OBStreamType type) {
    switch(type) {
    case OB_STREAM_VIDEO:
        return "VIDEO";
    case OB_STREAM_IR:
        return "IR";
    case OB_STREAM_COLOR:
        return "COLOR";
    case OB_STREAM_DEPTH:
        return "DEPTH";
    case OB_STREAM_ACCEL:
        return "ACCEL";
    case OB_STREAM_GYRO:
        return "GYRO";
    case OB_STREAM_IR_LEFT:
        return "IR_LEFT";
    case OB_STREAM_IR_RIGHT:
        return "IR_RIGHT";
    case OB_STREAM_RAW_PHASE:
        return "RAW_PHASE";
    default:
        return "UNKNOWN";
    }
}

static std::string FormatIntrinsic(const OBCameraIntrinsic &intr) {
    std::ostringstream out;
    out << std::fixed << std::setprecision(6);
    out << intr.width << "x" << intr.height << " fx=" << intr.fx << " fy=" << intr.fy << " cx=" << intr.cx << " cy=" << intr.cy;
    return out.str();
}

static std::string FormatDistortion(const OBCameraDistortion &dist) {
    std::ostringstream out;
    out << std::fixed << std::setprecision(8);
    out << "k1=" << dist.k1 << " k2=" << dist.k2 << " k3=" << dist.k3 << " k4=" << dist.k4 << " k5=" << dist.k5 << " k6=" << dist.k6
        << " p1=" << dist.p1 << " p2=" << dist.p2;
    return out.str();
}

static void AppendCameraParam(std::ostringstream &out, const std::string &label, const OBCameraParam &param) {
    out << label << " depth: " << FormatIntrinsic(param.depthIntrinsic) << "\n\n";
    out << label << " rgb:   " << FormatIntrinsic(param.rgbIntrinsic) << "\n\n";
    out << label << " depth distortion: " << FormatDistortion(param.depthDistortion) << "\n\n";
    out << label << " rgb distortion:   " << FormatDistortion(param.rgbDistortion) << "\n\n";
    out << label << " depth->color R:";
    out << std::fixed << std::setprecision(8);
    for(int i = 0; i < 9; ++i) {
        out << " " << param.transform.rot[i];
    }
    out << "\n\n";
    out << label << " depth->color T(mm):";
    for(int i = 0; i < 3; ++i) {
        out << " " << param.transform.trans[i];
    }
    out << "\n\n";
}

static NSColor *ColorFromHex(uint32_t rgb) {
    return [NSColor colorWithCalibratedRed:((rgb >> 16) & 0xff) / 255.0
                                     green:((rgb >> 8) & 0xff) / 255.0
                                      blue:(rgb & 0xff) / 255.0
                                     alpha:1.0];
}

static NSTextField *MakeLabel(NSString *text, NSFont *font, NSColor *color) {
    NSTextField *label = [NSTextField labelWithString:text];
    label.font        = font;
    label.textColor   = color;
    label.lineBreakMode = NSLineBreakByTruncatingTail;
    return label;
}

static bool CreateImageFromBGRA(const std::vector<uint8_t> &bgra, int width, int height, CGImageRef *imageOut) {
    if(bgra.empty() || width <= 0 || height <= 0) {
        return false;
    }
    NSData *data = [NSData dataWithBytes:bgra.data() length:bgra.size()];
    CGDataProviderRef provider = CGDataProviderCreateWithCFData((__bridge CFDataRef)data);
    if(!provider) {
        return false;
    }
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    CGImageRef image = CGImageCreate(width, height, 8, 32, width * 4, colorSpace,
                                     kCGBitmapByteOrder32Little | kCGImageAlphaPremultipliedFirst, provider, nullptr, false,
                                     kCGRenderingIntentDefault);
    CGColorSpaceRelease(colorSpace);
    CGDataProviderRelease(provider);
    if(!image) {
        return false;
    }
    *imageOut = image;
    return true;
}

static NSImage *NSImageFromBGRA(const std::vector<uint8_t> &bgra, int width, int height) {
    CGImageRef image = nullptr;
    if(!CreateImageFromBGRA(bgra, width, height, &image)) {
        return nil;
    }
    NSImage *nsImage = [[NSImage alloc] initWithCGImage:image size:NSMakeSize(width, height)];
    CGImageRelease(image);
    return nsImage;
}

static bool WriteBGRAPNG(const std::vector<uint8_t> &bgra, int width, int height, NSString *path) {
    CGImageRef image = nullptr;
    if(!CreateImageFromBGRA(bgra, width, height, &image)) {
        return false;
    }
    NSURL *url = [NSURL fileURLWithPath:path];
    CGImageDestinationRef dest =
        CGImageDestinationCreateWithURL((__bridge CFURLRef)url, (__bridge CFStringRef)@"public.png", 1, nullptr);
    if(!dest) {
        CGImageRelease(image);
        return false;
    }
    CGImageDestinationAddImage(dest, image, nullptr);
    bool ok = CGImageDestinationFinalize(dest);
    CFRelease(dest);
    CGImageRelease(image);
    return ok;
}

static void DepthColor(float normalized, uint8_t &r, uint8_t &g, uint8_t &b) {
    normalized = std::clamp(normalized, 0.0f, 1.0f);
    float x = normalized * 4.0f;
    r       = static_cast<uint8_t>(255.0f * std::clamp(std::min(x - 1.5f, -x + 4.5f), 0.0f, 1.0f));
    g       = static_cast<uint8_t>(255.0f * std::clamp(std::min(x - 0.5f, -x + 3.5f), 0.0f, 1.0f));
    b       = static_cast<uint8_t>(255.0f * std::clamp(std::min(x + 0.5f, -x + 2.5f), 0.0f, 1.0f));
}

static std::vector<uint8_t> DepthToBGRA(const uint16_t *depth, int width, int height, float scale) {
    std::vector<uint8_t> bgra(static_cast<size_t>(width) * static_cast<size_t>(height) * 4);
    const float          minMm = 250.0f;
    const float          maxMm = 5000.0f;
    for(int i = 0; i < width * height; ++i) {
        uint8_t r = 0, g = 0, b = 0;
        if(depth[i] > 0) {
            float mm = static_cast<float>(depth[i]) * scale;
            DepthColor((mm - minMm) / (maxMm - minMm), r, g, b);
        }
        bgra[i * 4 + 0] = b;
        bgra[i * 4 + 1] = g;
        bgra[i * 4 + 2] = r;
        bgra[i * 4 + 3] = 255;
    }
    return bgra;
}

static bool WriteDepthPGM(const std::vector<uint16_t> &depth, int width, int height, NSString *path) {
    if(depth.empty() || width <= 0 || height <= 0) {
        return false;
    }
    std::ofstream file(StdString(path), std::ios::binary);
    if(!file) {
        return false;
    }
    file << "P5\n" << width << " " << height << "\n65535\n";
    for(uint16_t value : depth) {
        char hi = static_cast<char>((value >> 8) & 0xff);
        char lo = static_cast<char>(value & 0xff);
        file.write(&hi, 1);
        file.write(&lo, 1);
    }
    return static_cast<bool>(file);
}

static OBCameraIntrinsic ScaleIntrinsic(const OBCameraIntrinsic &base, int width, int height) {
    OBCameraIntrinsic scaled = base;
    if(base.width > 0 && base.height > 0) {
        float sx   = static_cast<float>(width) / static_cast<float>(base.width);
        float sy   = static_cast<float>(height) / static_cast<float>(base.height);
        scaled.fx  = base.fx * sx;
        scaled.fy  = base.fy * sy;
        scaled.cx  = base.cx * sx;
        scaled.cy  = base.cy * sy;
        scaled.width  = width;
        scaled.height = height;
    }
    return scaled;
}

class OrbbecDepthEngine {
public:
    OrbbecDepthEngine() {
        refreshDeviceInfo();
    }

    ~OrbbecDepthEngine() {
        setEnabled(false, false);
    }

    bool refreshDeviceInfo() {
        std::lock_guard<std::mutex> lock(controlMutex_);
        if(running_) {
            status_ = "Device refresh skipped while depth stream is running.";
            return false;
        }

        std::ostringstream info;
        bool               ok = false;
        try {
            info << "OrbbecSDK " << ob::Version::getMajor() << "." << ob::Version::getMinor() << "." << ob::Version::getPatch()
                 << " stage=" << ob::Version::getStageVersion() << "\n";
            context_ = std::make_shared<ob::Context>();
            auto devList = context_->queryDeviceList();
            info << "Device count: " << devList->deviceCount() << "\n";
            if(devList->deviceCount() == 0) {
                device_.reset();
                status_ = "No Orbbec device found.";
                infoText_ = info.str();
                return false;
            }

            device_ = devList->getDevice(0);
            auto devInfo = device_->getDeviceInfo();
            info << "\nDevice #0\n";
            info << "Name: " << devInfo->name() << "\n";
            info << "Serial: " << devInfo->serialNumber() << "\n";
            info << "Firmware: " << devInfo->firmwareVersion() << "\n";
            info << "VID/PID: 0x" << std::hex << devInfo->vid() << "/0x" << devInfo->pid() << std::dec << "\n";
            info << "UID: " << devInfo->uid() << "\n";
            info << "Connection: " << devInfo->connectionType() << "\n";

            calibrationParams_.clear();
            try {
                auto paramList = device_->getCalibrationCameraParamList();
                info << "\nCalibration sets: " << paramList->count() << "\n";
                for(uint32_t i = 0; i < paramList->count(); ++i) {
                    OBCameraParam param = paramList->getCameraParam(i);
                    calibrationParams_.push_back(param);
                    AppendCameraParam(info, "Calibration[" + std::to_string(i) + "]", param);
                }
            }
            catch(ob::Error &e) {
                info << "Calibration error: " << SDKErrorString(e) << "\n";
            }

            try {
                auto sensors = device_->getSensorList();
                info << "\nSensors: " << sensors->count() << "\n";
                for(uint32_t s = 0; s < sensors->count(); ++s) {
                    auto sensor = sensors->getSensor(s);
                    info << "  " << s << ": " << SensorName(sensor->type()) << "\n";
                    try {
                        auto profiles = sensor->getStreamProfileList();
                        for(uint32_t p = 0; p < profiles->count(); ++p) {
                            auto profile = profiles->getProfile(p);
                            info << "    " << StreamName(profile->type()) << " fmt=" << static_cast<int>(profile->format());
                            if(profile->is<ob::VideoStreamProfile>()) {
                                auto video = profile->as<ob::VideoStreamProfile>();
                                info << " " << video->width() << "x" << video->height() << "@" << video->fps();
                            }
                            info << "\n";
                        }
                    }
                    catch(ob::Error &e) {
                        info << "    profiles error: " << SDKErrorString(e) << "\n";
                    }
                }
            }
            catch(ob::Error &e) {
                info << "Sensor list error: " << SDKErrorString(e) << "\n";
            }

            ok = true;
            status_ = "Device metadata refreshed.";
        }
        catch(ob::Error &e) {
            status_ = "SDK error: " + SDKErrorString(e);
            info << "\n" << status_ << "\n";
        }
        catch(const std::exception &e) {
            status_ = std::string("Error: ") + e.what();
            info << "\n" << status_ << "\n";
        }
        infoText_ = info.str();
        return ok;
    }

    void setEnabled(bool depthPreview, bool pointCloud) {
        std::thread workerToJoin;
        bool        startAfterJoin = false;
        bool        shouldRun = depthPreview || pointCloud;
        {
            std::lock_guard<std::mutex> lock(controlMutex_);
            wantDepthPreview_.store(depthPreview);
            wantPointCloud_.store(pointCloud);

            if(!running_ && worker_.joinable()) {
                workerToJoin = std::move(worker_);
                startAfterJoin = shouldRun;
            }
            else if(shouldRun && !running_) {
                stopRequested_.store(false);
                running_ = true;
                worker_  = std::thread(&OrbbecDepthEngine::captureLoop, this);
            }
            else if(!shouldRun && running_) {
                stopRequested_.store(true);
                running_ = false;
                if(worker_.joinable()) {
                    workerToJoin = std::move(worker_);
                }
            }
        }
        if(workerToJoin.joinable()) {
            workerToJoin.join();
        }
        if(startAfterJoin) {
            std::lock_guard<std::mutex> lock(controlMutex_);
            if((wantDepthPreview_.load() || wantPointCloud_.load()) && !running_) {
                stopRequested_.store(false);
                running_ = true;
                worker_  = std::thread(&OrbbecDepthEngine::captureLoop, this);
            }
        }
    }

    std::string infoText() const {
        std::lock_guard<std::mutex> lock(infoMutex_);
        return infoText_;
    }

    std::string status() const {
        std::lock_guard<std::mutex> lock(infoMutex_);
        return status_;
    }

    bool copyDepthImage(std::vector<uint8_t> &bgra, int &width, int &height, uint64_t &version) const {
        std::lock_guard<std::mutex> lock(frameMutex_);
        if(depthBGRA_.empty()) {
            return false;
        }
        bgra    = depthBGRA_;
        width   = depthWidth_;
        height  = depthHeight_;
        version = depthVersion_;
        return true;
    }

    bool copyCloud(std::vector<CloudPoint> &points, uint64_t &version) const {
        std::lock_guard<std::mutex> lock(frameMutex_);
        if(previewCloud_.empty()) {
            return false;
        }
        points  = previewCloud_;
        version = cloudVersion_;
        return true;
    }

    std::vector<std::string> saveDepthSnapshot(NSString *directory) const {
        std::vector<uint16_t> raw;
        std::vector<uint8_t>  bgra;
        int                   width = 0;
        int                   height = 0;
        {
            std::lock_guard<std::mutex> lock(frameMutex_);
            raw    = rawDepth_;
            bgra   = depthBGRA_;
            width  = depthWidth_;
            height = depthHeight_;
        }
        std::vector<std::string> paths;
        if(raw.empty() || bgra.empty()) {
            return paths;
        }
        NSString *base = [NSString stringWithFormat:@"depth_%@", Timestamp()];
        NSString *png  = [directory stringByAppendingPathComponent:[base stringByAppendingString:@"_visual.png"]];
        NSString *pgm  = [directory stringByAppendingPathComponent:[base stringByAppendingString:@"_raw16.pgm"]];
        if(WriteBGRAPNG(bgra, width, height, png)) {
            paths.push_back(StdString(png));
        }
        if(WriteDepthPGM(raw, width, height, pgm)) {
            paths.push_back(StdString(pgm));
        }
        return paths;
    }

    std::string savePointCloud(NSString *directory) const {
        std::vector<uint16_t> raw;
        int                   width = 0;
        int                   height = 0;
        float                 scale = 1.0f;
        OBCameraIntrinsic     intr{};
        {
            std::lock_guard<std::mutex> lock(frameMutex_);
            raw    = rawDepth_;
            width  = depthWidth_;
            height = depthHeight_;
            scale  = depthScale_;
            intr   = currentDepthIntrinsic_;
        }
        if(raw.empty() || width <= 0 || height <= 0 || intr.fx == 0.0f || intr.fy == 0.0f) {
            return {};
        }

        NSString *path = [directory stringByAppendingPathComponent:[NSString stringWithFormat:@"pointcloud_%@.ply", Timestamp()]];
        std::ofstream file(StdString(path));
        if(!file) {
            return {};
        }
        size_t validCount = 0;
        for(uint16_t value : raw) {
            if(value > 0) {
                ++validCount;
            }
        }
        file << "ply\nformat ascii 1.0\n";
        file << "element vertex " << validCount << "\n";
        file << "property float x\nproperty float y\nproperty float z\n";
        file << "property uchar red\nproperty uchar green\nproperty uchar blue\n";
        file << "end_header\n";
        file << std::fixed << std::setprecision(6);
        for(int y = 0; y < height; ++y) {
            for(int x = 0; x < width; ++x) {
                uint16_t value = raw[y * width + x];
                if(value == 0) {
                    continue;
                }
                float zMm = static_cast<float>(value) * scale;
                float z   = zMm / 1000.0f;
                float px  = (static_cast<float>(x) - intr.cx) * zMm / intr.fx / 1000.0f;
                float py  = (static_cast<float>(y) - intr.cy) * zMm / intr.fy / 1000.0f;
                uint8_t r, g, b;
                DepthColor((zMm - 250.0f) / (5000.0f - 250.0f), r, g, b);
                file << px << " " << py << " " << z << " " << static_cast<int>(r) << " " << static_cast<int>(g) << " "
                     << static_cast<int>(b) << "\n";
            }
        }
        return file ? StdString(path) : std::string();
    }

private:
    OBCameraIntrinsic chooseDepthIntrinsic(int width, int height) const {
        for(const auto &param : calibrationParams_) {
            if(param.depthIntrinsic.width == width && param.depthIntrinsic.height == height) {
                return param.depthIntrinsic;
            }
        }
        if(!calibrationParams_.empty()) {
            return ScaleIntrinsic(calibrationParams_[0].depthIntrinsic, width, height);
        }
        OBCameraIntrinsic intr{};
        intr.width  = width;
        intr.height = height;
        intr.fx     = width;
        intr.fy     = width;
        intr.cx     = width * 0.5f;
        intr.cy     = height * 0.5f;
        return intr;
    }

    void updateCloudLocked(const std::vector<uint16_t> &raw, int width, int height, float scale, const OBCameraIntrinsic &intr) {
        previewCloud_.clear();
        if(raw.empty() || intr.fx == 0.0f || intr.fy == 0.0f) {
            return;
        }
        int step = std::max(2, width / 180);
        previewCloud_.reserve(static_cast<size_t>(width / step) * static_cast<size_t>(height / step));
        for(int y = 0; y < height; y += step) {
            for(int x = 0; x < width; x += step) {
                uint16_t value = raw[y * width + x];
                if(value == 0) {
                    continue;
                }
                float zMm = static_cast<float>(value) * scale;
                if(zMm < 250.0f || zMm > 6000.0f) {
                    continue;
                }
                CloudPoint point{};
                point.z = zMm / 1000.0f;
                point.x = (static_cast<float>(x) - intr.cx) * zMm / intr.fx / 1000.0f;
                point.y = (static_cast<float>(y) - intr.cy) * zMm / intr.fy / 1000.0f;
                DepthColor((zMm - 250.0f) / (5000.0f - 250.0f), point.r, point.g, point.b);
                previewCloud_.push_back(point);
            }
        }
        ++cloudVersion_;
    }

    void captureLoop() {
        std::shared_ptr<ob::Pipeline> pipeline;
        try {
            {
                std::lock_guard<std::mutex> lock(infoMutex_);
                status_ = "Starting depth pipeline...";
            }
            if(!device_) {
                refreshDeviceInfo();
            }
            if(!device_) {
                throw std::runtime_error("No Orbbec device available");
            }

            pipeline    = std::make_shared<ob::Pipeline>(device_);
            auto config = std::make_shared<ob::Config>();
            config->enableVideoStream(OB_STREAM_DEPTH);
            pipeline->start(config);
            {
                std::lock_guard<std::mutex> lock(infoMutex_);
                status_ = "Depth pipeline running.";
            }

            while(!stopRequested_.load()) {
                auto frames = pipeline->waitForFrames(100);
                if(!frames || !frames->depthFrame()) {
                    continue;
                }
                auto      depthFrame = frames->depthFrame();
                int       width      = static_cast<int>(depthFrame->width());
                int       height     = static_cast<int>(depthFrame->height());
                float     scale      = depthFrame->getValueScale();
                auto     *data       = static_cast<uint16_t *>(depthFrame->data());
                size_t    count      = static_cast<size_t>(width) * static_cast<size_t>(height);
                std::vector<uint16_t> raw(data, data + count);
                OBCameraIntrinsic intr = chooseDepthIntrinsic(width, height);

                std::vector<uint8_t> bgra;
                if(wantDepthPreview_.load()) {
                    bgra = DepthToBGRA(raw.data(), width, height, scale);
                }

                {
                    std::lock_guard<std::mutex> lock(frameMutex_);
                    rawDepth_              = std::move(raw);
                    depthWidth_            = width;
                    depthHeight_           = height;
                    depthScale_            = scale;
                    currentDepthIntrinsic_ = intr;
                    if(!bgra.empty()) {
                        depthBGRA_ = std::move(bgra);
                        ++depthVersion_;
                    }
                    if(wantPointCloud_.load()) {
                        updateCloudLocked(rawDepth_, depthWidth_, depthHeight_, depthScale_, currentDepthIntrinsic_);
                    }
                }
            }
            {
                std::lock_guard<std::mutex> lock(infoMutex_);
                status_ = "Stopping depth pipeline...";
            }
            pipeline->stop();
            {
                std::lock_guard<std::mutex> lock(infoMutex_);
                status_ = "Depth pipeline stopped.";
            }
        }
        catch(ob::Error &e) {
            std::lock_guard<std::mutex> lock(infoMutex_);
            status_ = "Depth SDK error: " + SDKErrorString(e);
        }
        catch(const std::exception &e) {
            std::lock_guard<std::mutex> lock(infoMutex_);
            status_ = std::string("Depth error: ") + e.what();
        }
        {
            std::lock_guard<std::mutex> lock(controlMutex_);
            running_ = false;
        }
    }

    mutable std::mutex controlMutex_;
    mutable std::mutex infoMutex_;
    mutable std::mutex frameMutex_;

    std::shared_ptr<ob::Context> context_;
    std::shared_ptr<ob::Device>  device_;
    std::vector<OBCameraParam>   calibrationParams_;

    std::thread       worker_;
    std::atomic<bool> stopRequested_{false};
    std::atomic<bool> wantDepthPreview_{false};
    std::atomic<bool> wantPointCloud_{false};
    bool              running_ = false;

    std::string infoText_;
    std::string status_;

    std::vector<uint16_t> rawDepth_;
    std::vector<uint8_t>  depthBGRA_;
    std::vector<CloudPoint> previewCloud_;
    int                   depthWidth_ = 0;
    int                   depthHeight_ = 0;
    float                 depthScale_ = 1.0f;
    OBCameraIntrinsic     currentDepthIntrinsic_{};
    uint64_t              depthVersion_ = 0;
    uint64_t              cloudVersion_ = 0;
};

}  // namespace

@interface RGBCapture : NSObject <AVCaptureVideoDataOutputSampleBufferDelegate>
- (void)start;
- (void)stop;
- (NSString *)status;
- (BOOL)copyBGRA:(std::vector<uint8_t> &)bgra width:(int &)width height:(int &)height version:(uint64_t &)version;
- (NSString *)saveLatestToDirectory:(NSString *)directory;
@end

@implementation RGBCapture {
    AVCaptureSession *_session;
    dispatch_queue_t  _queue;
    std::mutex        _mutex;
    std::vector<uint8_t> _bgra;
    int               _width;
    int               _height;
    uint64_t          _version;
    NSString         *_status;
}

- (instancetype)init {
    self = [super init];
    if(self) {
        _queue   = dispatch_queue_create("orbbec.viewer.rgb", DISPATCH_QUEUE_SERIAL);
        _width   = 0;
        _height  = 0;
        _version = 0;
        _status  = @"RGB stream stopped.";
    }
    return self;
}

- (AVCaptureDevice *)preferredDevice {
    NSArray<AVCaptureDevice *> *devices = [AVCaptureDevice devicesWithMediaType:AVMediaTypeVideo];
    AVCaptureDevice            *fallback = devices.firstObject;
    AVCaptureDevice            *best = nil;
    NSInteger                   bestScore = NSIntegerMin;
    for(AVCaptureDevice *device in devices) {
        NSString *name = device.localizedName.lowercaseString;
        NSInteger score = 0;
        if([name containsString:@"orbbec"]) {
            score += 100;
        }
        if([name containsString:@"usb"]) {
            score += 80;
        }
        if([name containsString:@"camera"]) {
            score += 20;
        }
        if([name containsString:@"facetime"] || [name containsString:@"iphone"] || [name containsString:@"continuity"]) {
            score -= 100;
        }
        if(score > bestScore) {
            bestScore = score;
            best      = device;
        }
    }
    return best ?: fallback;
}

- (void)start {
    if(_session && _session.isRunning) {
        return;
    }

    AVAuthorizationStatus auth = [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeVideo];
    if(auth == AVAuthorizationStatusNotDetermined) {
        _status = @"Waiting for macOS camera permission...";
        [AVCaptureDevice requestAccessForMediaType:AVMediaTypeVideo
                                 completionHandler:^(BOOL granted) {
                                   dispatch_async(dispatch_get_main_queue(), ^{
                                     if(granted) {
                                         [self start];
                                     }
                                     else {
                                         self->_status = @"RGB permission denied.";
                                     }
                                   });
                                 }];
        return;
    }
    if(auth == AVAuthorizationStatusDenied || auth == AVAuthorizationStatusRestricted) {
        _status = @"RGB permission denied in macOS settings.";
        return;
    }

    AVCaptureDevice *device = [self preferredDevice];
    if(!device) {
        _status = @"No RGB camera found.";
        return;
    }

    NSError *error = nil;
    AVCaptureDeviceInput *input = [AVCaptureDeviceInput deviceInputWithDevice:device error:&error];
    if(!input) {
        _status = [NSString stringWithFormat:@"RGB input error: %@", error.localizedDescription];
        return;
    }

    AVCaptureSession *session = [[AVCaptureSession alloc] init];
    session.sessionPreset = AVCaptureSessionPreset640x480;
    if([session canAddInput:input]) {
        [session addInput:input];
    }
    else {
        _status = @"Cannot add RGB input.";
        return;
    }

    AVCaptureVideoDataOutput *output = [[AVCaptureVideoDataOutput alloc] init];
    output.alwaysDiscardsLateVideoFrames = YES;
    output.videoSettings = @{ (__bridge NSString *)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_32BGRA) };
    [output setSampleBufferDelegate:self queue:_queue];
    if([session canAddOutput:output]) {
        [session addOutput:output];
    }
    else {
        _status = @"Cannot add RGB output.";
        return;
    }

    _session = session;
    [_session startRunning];
    _status = [NSString stringWithFormat:@"RGB running: %@", device.localizedName];
}

- (void)stop {
    if(_session) {
        [_session stopRunning];
        _session = nil;
    }
    _status = @"RGB stream stopped.";
}

- (NSString *)status {
    return _status ?: @"";
}

- (BOOL)copyBGRA:(std::vector<uint8_t> &)bgra width:(int &)width height:(int &)height version:(uint64_t &)version {
    std::lock_guard<std::mutex> lock(_mutex);
    if(_bgra.empty()) {
        return NO;
    }
    bgra    = _bgra;
    width   = _width;
    height  = _height;
    version = _version;
    return YES;
}

- (NSString *)saveLatestToDirectory:(NSString *)directory {
    std::vector<uint8_t> bgra;
    int                 width = 0;
    int                 height = 0;
    uint64_t            version = 0;
    if(![self copyBGRA:bgra width:width height:height version:version]) {
        return nil;
    }
    NSString *path = [directory stringByAppendingPathComponent:[NSString stringWithFormat:@"rgb_%@.png", Timestamp()]];
    return WriteBGRAPNG(bgra, width, height, path) ? path : nil;
}

- (void)captureOutput:(AVCaptureOutput *)output
    didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
           fromConnection:(AVCaptureConnection *)connection {
    CVImageBufferRef imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
    if(!imageBuffer) {
        return;
    }
    CVPixelBufferLockBaseAddress(imageBuffer, kCVPixelBufferLock_ReadOnly);
    int      width       = static_cast<int>(CVPixelBufferGetWidth(imageBuffer));
    int      height      = static_cast<int>(CVPixelBufferGetHeight(imageBuffer));
    size_t   bytesPerRow = CVPixelBufferGetBytesPerRow(imageBuffer);
    uint8_t *base        = static_cast<uint8_t *>(CVPixelBufferGetBaseAddress(imageBuffer));
    if(base && width > 0 && height > 0) {
        std::vector<uint8_t> frame(static_cast<size_t>(width) * static_cast<size_t>(height) * 4);
        for(int y = 0; y < height; ++y) {
            std::memcpy(frame.data() + static_cast<size_t>(y) * width * 4, base + static_cast<size_t>(y) * bytesPerRow,
                        static_cast<size_t>(width) * 4);
        }
        {
            std::lock_guard<std::mutex> lock(_mutex);
            _bgra   = std::move(frame);
            _width  = width;
            _height = height;
            ++_version;
        }
    }
    CVPixelBufferUnlockBaseAddress(imageBuffer, kCVPixelBufferLock_ReadOnly);
}

@end

@interface FlippedView : NSView
@end

@implementation FlippedView
- (BOOL)isFlipped {
    return YES;
}
@end

@interface PointCloudView : NSView
- (void)setCloudPoints:(const std::vector<CloudPoint> &)points;
@end

@implementation PointCloudView {
    std::mutex              _mutex;
    std::vector<CloudPoint> _points;
    float                   _yaw;
    float                   _pitch;
    float                   _zoom;
    NSPoint                 _lastDrag;
}

- (instancetype)initWithFrame:(NSRect)frameRect {
    self = [super initWithFrame:frameRect];
    if(self) {
        self.wantsLayer = YES;
        self.layer.backgroundColor = ColorFromHex(0x080a0e).CGColor;
        _yaw   = 0.25f;
        _pitch = -0.18f;
        _zoom  = 1.0f;
    }
    return self;
}

- (BOOL)isFlipped {
    return YES;
}

- (void)setCloudPoints:(const std::vector<CloudPoint> &)points {
    {
        std::lock_guard<std::mutex> lock(_mutex);
        _points = points;
    }
    [self setNeedsDisplay:YES];
}

- (void)drawRect:(NSRect)dirtyRect {
    CGContextRef ctx = [[NSGraphicsContext currentContext] CGContext];
    CGContextSetRGBFillColor(ctx, 0.03, 0.04, 0.06, 1.0);
    CGContextFillRect(ctx, self.bounds);

    std::vector<CloudPoint> points;
    {
        std::lock_guard<std::mutex> lock(_mutex);
        points = _points;
    }

    if(points.empty()) {
        NSDictionary *attrs = @{
            NSFontAttributeName : [NSFont systemFontOfSize:14 weight:NSFontWeightMedium],
            NSForegroundColorAttributeName : ColorFromHex(0x8b93a3)
        };
        [@"Point cloud paused" drawAtPoint:NSMakePoint(18, 18) withAttributes:attrs];
        return;
    }

    CGFloat midX = NSMidX(self.bounds);
    CGFloat midY = NSMidY(self.bounds);
    float   scale = static_cast<float>(std::min(self.bounds.size.width, self.bounds.size.height)) * 0.42f * _zoom;
    float   cy = std::cos(_yaw), sy = std::sin(_yaw);
    float   cp = std::cos(_pitch), sp = std::sin(_pitch);

    for(const auto &p : points) {
        float zc = p.z - 1.7f;
        float x1 = p.x * cy + zc * sy;
        float z1 = -p.x * sy + zc * cy;
        float y1 = p.y * cp - z1 * sp;
        CGFloat sx = midX + x1 * scale;
        CGFloat syy = midY + y1 * scale;
        if(sx < 0 || sx >= self.bounds.size.width || syy < 0 || syy >= self.bounds.size.height) {
            continue;
        }
        CGContextSetRGBFillColor(ctx, p.r / 255.0, p.g / 255.0, p.b / 255.0, 1.0);
        CGContextFillRect(ctx, CGRectMake(sx, syy, 1.4, 1.4));
    }
}

- (void)mouseDown:(NSEvent *)event {
    _lastDrag = [self convertPoint:event.locationInWindow fromView:nil];
}

- (void)mouseDragged:(NSEvent *)event {
    NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
    _yaw += static_cast<float>((point.x - _lastDrag.x) * 0.008);
    _pitch += static_cast<float>((point.y - _lastDrag.y) * 0.008);
    _pitch = std::clamp(_pitch, -1.3f, 1.3f);
    _lastDrag = point;
    [self setNeedsDisplay:YES];
}

- (void)scrollWheel:(NSEvent *)event {
    _zoom *= std::pow(1.05f, static_cast<float>(-event.scrollingDeltaY));
    _zoom = std::clamp(_zoom, 0.35f, 4.0f);
    [self setNeedsDisplay:YES];
}

@end

@interface AppDelegate : NSObject <NSApplicationDelegate>
@end

@implementation AppDelegate {
    NSWindow      *_window;
    FlippedView   *_root;
    NSTextField   *_titleLabel;
    NSScrollView  *_infoScroll;
    NSTextView    *_infoTextView;
    NSTextField   *_statusLabel;
    NSImageView   *_rgbImageView;
    NSImageView   *_depthImageView;
    PointCloudView *_cloudView;
    NSBox         *_rgbBox;
    NSBox         *_depthBox;
    NSBox         *_cloudBox;
    NSButton      *_rgbToggle;
    NSButton      *_depthToggle;
    NSButton      *_cloudToggle;
    NSMutableArray<NSButton *> *_actionButtons;
    NSTimer       *_timer;

    RGBCapture *_rgb;
    std::unique_ptr<OrbbecDepthEngine> _depth;
    uint64_t _lastRGBVersion;
    uint64_t _lastDepthVersion;
    uint64_t _lastCloudVersion;
}

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    _rgb = [[RGBCapture alloc] init];
    _depth = std::make_unique<OrbbecDepthEngine>();
    _lastRGBVersion = _lastDepthVersion = _lastCloudVersion = 0;

    NSRect frame = NSMakeRect(80, 80, 1320, 860);
    _window = [[NSWindow alloc] initWithContentRect:frame
                                          styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable |
                                                    NSWindowStyleMaskMiniaturizable
                                            backing:NSBackingStoreBuffered
                                              defer:NO];
    _window.title = @"Orbbec Test Viewer";
    _window.minSize = NSMakeSize(1040, 700);
    _root = [[FlippedView alloc] initWithFrame:NSMakeRect(0, 0, frame.size.width, frame.size.height)];
    _root.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    _root.wantsLayer = YES;
    _root.layer.backgroundColor = ColorFromHex(0xf5f7fb).CGColor;
    _window.contentView = _root;

    [self buildControls];
    [self layoutViews];
    [self refreshInfo:nil];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(windowDidResize:)
                                                 name:NSWindowDidResizeNotification
                                               object:_window];

    _timer = [NSTimer scheduledTimerWithTimeInterval:1.0 / 24.0 target:self selector:@selector(tick:) userInfo:nil repeats:YES];
    [_window makeKeyAndOrderFront:nil];
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender {
    return YES;
}

- (void)applicationWillTerminate:(NSNotification *)notification {
    [_timer invalidate];
    [_rgb stop];
    if(_depth) {
        _depth->setEnabled(false, false);
    }
}

- (void)buildControls {
    NSFont *titleFont = [NSFont systemFontOfSize:18 weight:NSFontWeightSemibold];
    _titleLabel = MakeLabel(@"Orbbec Test Viewer", titleFont, ColorFromHex(0x1f2937));
    [_root addSubview:_titleLabel];

    _rgbToggle = [NSButton checkboxWithTitle:@"RGB" target:self action:@selector(toggleStreams:)];
    _depthToggle = [NSButton checkboxWithTitle:@"Depth" target:self action:@selector(toggleStreams:)];
    _cloudToggle = [NSButton checkboxWithTitle:@"Point Cloud" target:self action:@selector(toggleStreams:)];
    for(NSButton *button in @[ _rgbToggle, _depthToggle, _cloudToggle ]) {
        button.font = [NSFont systemFontOfSize:13 weight:NSFontWeightMedium];
        [_root addSubview:button];
    }

    NSArray<NSArray *> *buttons = @[
        @[ @"Reload Device", NSStringFromSelector(@selector(refreshInfo:)) ],
        @[ @"Save RGB", NSStringFromSelector(@selector(saveRGB:)) ],
        @[ @"Save Depth", NSStringFromSelector(@selector(saveDepth:)) ],
        @[ @"Save PointCloud", NSStringFromSelector(@selector(saveCloud:)) ],
    ];
    NSInteger tag = 2000;
    for(NSArray *item in buttons) {
        NSButton *button = [NSButton buttonWithTitle:item[0] target:self action:NSSelectorFromString(item[1])];
        button.bezelStyle = NSBezelStyleRounded;
        button.font = [NSFont systemFontOfSize:13 weight:NSFontWeightMedium];
        if(!_actionButtons) {
            _actionButtons = [NSMutableArray array];
        }
        [_actionButtons addObject:button];
        tag++;
        [_root addSubview:button];
    }

    _statusLabel = MakeLabel(@"Ready", [NSFont systemFontOfSize:12 weight:NSFontWeightRegular], ColorFromHex(0x475569));
    [_root addSubview:_statusLabel];

    _infoScroll = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    _infoScroll.hasVerticalScroller = YES;
    _infoScroll.borderType = NSLineBorder;
    _infoScroll.autohidesScrollers = YES;
    _infoTextView = [[NSTextView alloc] initWithFrame:NSZeroRect];
    _infoTextView.editable = NO;
    _infoTextView.selectable = YES;
    _infoTextView.font = [NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightRegular];
    _infoTextView.textColor = ColorFromHex(0x111827);
    _infoTextView.backgroundColor = ColorFromHex(0xffffff);
    _infoScroll.documentView = _infoTextView;
    [_root addSubview:_infoScroll];

    _rgbImageView = [[NSImageView alloc] initWithFrame:NSZeroRect];
    _depthImageView = [[NSImageView alloc] initWithFrame:NSZeroRect];
    for(NSImageView *view in @[ _rgbImageView, _depthImageView ]) {
        view.imageScaling = NSImageScaleProportionallyUpOrDown;
        view.wantsLayer = YES;
        view.layer.backgroundColor = ColorFromHex(0x090b10).CGColor;
    }
    _cloudView = [[PointCloudView alloc] initWithFrame:NSZeroRect];

    _rgbBox = [self addPanelWithTitle:@"RGB Video" content:_rgbImageView];
    _depthBox = [self addPanelWithTitle:@"Depth Video" content:_depthImageView];
    _cloudBox = [self addPanelWithTitle:@"Point Cloud" content:_cloudView];
}

- (NSBox *)addPanelWithTitle:(NSString *)title content:(NSView *)content {
    NSBox *box = [[NSBox alloc] initWithFrame:NSZeroRect];
    box.title = title;
    box.titleFont = [NSFont systemFontOfSize:13 weight:NSFontWeightSemibold];
    box.boxType = NSBoxCustom;
    box.borderType = NSLineBorder;
    box.cornerRadius = 6;
    box.borderColor = ColorFromHex(0xd7dce5);
    box.fillColor = ColorFromHex(0xffffff);
    content.frame = NSMakeRect(10, 10, 100, 100);
    content.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [box.contentView addSubview:content];
    [_root addSubview:box];
    return box;
}

- (void)layoutViews {
    CGFloat w = _root.bounds.size.width;
    CGFloat h = _root.bounds.size.height;
    CGFloat margin = 16.0;
    CGFloat top = 14.0;
    CGFloat toolbarH = 72.0;
    CGFloat infoW = 390.0;
    CGFloat gap = 14.0;

    _titleLabel.frame = NSMakeRect(margin, top, 240, 28);
    _rgbToggle.frame = NSMakeRect(300, top + 2, 70, 24);
    _depthToggle.frame = NSMakeRect(374, top + 2, 86, 24);
    _cloudToggle.frame = NSMakeRect(468, top + 2, 120, 24);

    CGFloat buttonX = 610.0;
    for(NSUInteger i = 0; i < _actionButtons.count; ++i) {
        NSView *button = _actionButtons[i];
        CGFloat bw = i == 0 ? 118.0 : (i == 3 ? 132.0 : 100.0);
        button.frame = NSMakeRect(buttonX, top, bw, 28);
        buttonX += bw + 10.0;
    }
    _statusLabel.frame = NSMakeRect(margin, 46, w - margin * 2, 20);

    _infoScroll.frame = NSMakeRect(margin, toolbarH + margin, infoW, h - toolbarH - margin * 2);
    _infoTextView.frame = NSMakeRect(0, 0, infoW - 20, std::max(900.0, h - toolbarH - margin * 2));

    CGFloat rightX = margin + infoW + gap;
    CGFloat rightW = w - rightX - margin;
    CGFloat panelY = toolbarH + margin;
    CGFloat panelH = h - toolbarH - margin * 2;
    CGFloat topRowH = std::floor((panelH - gap) * 0.52);
    CGFloat bottomH = panelH - gap - topRowH;
    CGFloat halfW = std::floor((rightW - gap) / 2.0);

    _rgbBox.frame = NSMakeRect(rightX, panelY, halfW, topRowH);
    _depthBox.frame = NSMakeRect(rightX + halfW + gap, panelY, rightW - halfW - gap, topRowH);
    _cloudBox.frame = NSMakeRect(rightX, panelY + topRowH + gap, rightW, bottomH);
    for(NSBox *box in @[ _rgbBox, _depthBox, _cloudBox ]) {
        NSView *content = box.contentView.subviews.firstObject;
        content.frame = NSMakeRect(10, 10, box.contentView.bounds.size.width - 20, box.contentView.bounds.size.height - 20);
    }
}

- (void)windowDidResize:(NSNotification *)notification {
    [self layoutViews];
}

- (void)toggleStreams:(id)sender {
    if(_rgbToggle.state == NSControlStateValueOn) {
        [_rgb start];
    }
    else {
        [_rgb stop];
    }
    bool depthOn = _depthToggle.state == NSControlStateValueOn;
    bool cloudOn = _cloudToggle.state == NSControlStateValueOn;
    _depth->setEnabled(depthOn, cloudOn);
    [self updateStatus:@"Stream selection updated."];
}

- (void)refreshInfo:(id)sender {
    bool ok = _depth->refreshDeviceInfo();
    _infoTextView.string = NSStringFromStd(_depth->infoText());
    [self updateStatus:ok ? @"Device metadata refreshed." : NSStringFromStd(_depth->status())];
}

- (void)saveRGB:(id)sender {
    NSString *path = [_rgb saveLatestToDirectory:CaptureDirectory()];
    [self updateStatus:path ? [NSString stringWithFormat:@"Saved RGB: %@", path] : @"No RGB frame to save."];
}

- (void)saveDepth:(id)sender {
    auto paths = _depth->saveDepthSnapshot(CaptureDirectory());
    if(paths.empty()) {
        [self updateStatus:@"No depth frame to save."];
        return;
    }
    [self updateStatus:[NSString stringWithFormat:@"Saved depth: %lu files", static_cast<unsigned long>(paths.size())]];
}

- (void)saveCloud:(id)sender {
    std::string path = _depth->savePointCloud(CaptureDirectory());
    [self updateStatus:path.empty() ? @"No point cloud frame to save." : [NSString stringWithFormat:@"Saved point cloud: %@", NSStringFromStd(path)]];
}

- (void)updateStatus:(NSString *)message {
    NSString *status = [NSString stringWithFormat:@"%@ | RGB: %@ | Depth: %@", message, [_rgb status], NSStringFromStd(_depth->status())];
    _statusLabel.stringValue = status;
}

- (void)tick:(NSTimer *)timer {
    std::vector<uint8_t> bgra;
    int                 width = 0, height = 0;
    uint64_t            version = 0;
    if([_rgb copyBGRA:bgra width:width height:height version:version] && version != _lastRGBVersion) {
        _rgbImageView.image = NSImageFromBGRA(bgra, width, height);
        _lastRGBVersion = version;
    }

    if(_depth->copyDepthImage(bgra, width, height, version) && version != _lastDepthVersion) {
        _depthImageView.image = NSImageFromBGRA(bgra, width, height);
        _lastDepthVersion = version;
    }

    std::vector<CloudPoint> points;
    if(_depth->copyCloud(points, version) && version != _lastCloudVersion) {
        [_cloudView setCloudPoints:points];
        _lastCloudVersion = version;
    }
    _statusLabel.stringValue = [NSString stringWithFormat:@"RGB: %@ | Depth: %@", [_rgb status], NSStringFromStd(_depth->status())];
}

@end

static int SmokeTest() {
    @autoreleasepool {
        OrbbecDepthEngine engine;
        bool ok = engine.refreshDeviceInfo();
        std::cout << engine.infoText() << std::endl;
        NSArray<AVCaptureDevice *> *devices = [AVCaptureDevice devicesWithMediaType:AVMediaTypeVideo];
        std::cout << "AVFoundation RGB devices: " << devices.count << std::endl;
        for(AVCaptureDevice *device in devices) {
            std::cout << "  - " << StdString(device.localizedName) << std::endl;
        }
        return ok ? 0 : 1;
    }
}

int main(int argc, const char *argv[]) {
    for(int i = 1; i < argc; ++i) {
        if(std::string(argv[i]) == "--smoke-test") {
            return SmokeTest();
        }
    }

    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        AppDelegate *delegate = [[AppDelegate alloc] init];
        app.delegate = delegate;
        [app setActivationPolicy:NSApplicationActivationPolicyRegular];
        [app activateIgnoringOtherApps:YES];
        [app run];
    }
    return 0;
}
