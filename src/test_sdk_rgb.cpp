#include "libobsensor/ObSensor.hpp"
#include "libobsensor/hpp/Error.hpp"

#include <chrono>
#include <iostream>
#include <memory>
#include <string>
#include <thread>

namespace {

std::string sdkError(const ob::Error &e) {
    return std::string(e.getName()) + "(" + e.getArgs() + "): " + e.getMessage() + " type="
           + std::to_string(static_cast<int>(e.getExceptionType()));
}

std::string sensorName(OBSensorType type) {
    switch(type) {
    case OB_SENSOR_COLOR:
        return "COLOR";
    case OB_SENSOR_DEPTH:
        return "DEPTH";
    case OB_SENSOR_IR:
        return "IR";
    default:
        return "SENSOR_" + std::to_string(static_cast<int>(type));
    }
}

void listColorProfiles(std::shared_ptr<ob::Device> device) {
    auto sensors = device->getSensorList();
    std::cout << "Sensors: " << sensors->count() << "\n";
    for(uint32_t i = 0; i < sensors->count(); ++i) {
        auto sensor = sensors->getSensor(i);
        std::cout << "  " << i << ": " << sensorName(sensor->type()) << "\n";
        if(sensor->type() != OB_SENSOR_COLOR) {
            continue;
        }

        try {
            auto profiles = sensor->getStreamProfileList();
            std::cout << "    COLOR profile count: " << profiles->count() << "\n";
            for(uint32_t p = 0; p < profiles->count(); ++p) {
                auto profile = profiles->getProfile(p);
                std::cout << "    #" << p << " stream=" << static_cast<int>(profile->type())
                          << " fmt=" << static_cast<int>(profile->format());
                if(profile->is<ob::VideoStreamProfile>()) {
                    auto video = profile->as<ob::VideoStreamProfile>();
                    std::cout << " " << video->width() << "x" << video->height() << "@" << video->fps();
                }
                std::cout << "\n";
            }
        }
        catch(ob::Error &e) {
            std::cout << "    COLOR profile SDK error: " << sdkError(e) << "\n";
        }
        catch(const std::exception &e) {
            std::cout << "    COLOR profile error: " << e.what() << "\n";
        }
    }
}

}  // namespace

int main() {
    try {
        std::cout << "OrbbecSDK " << ob::Version::getMajor() << "." << ob::Version::getMinor() << "." << ob::Version::getPatch()
                  << " stage=" << ob::Version::getStageVersion() << "\n";

        auto context = std::make_shared<ob::Context>();
        auto devices = context->queryDeviceList();
        std::cout << "Device count: " << devices->deviceCount() << "\n";
        if(devices->deviceCount() == 0) {
            std::cout << "No Orbbec device found.\n";
            return 2;
        }

        auto device = devices->getDevice(0);
        auto info = device->getDeviceInfo();
        std::cout << "Device: " << info->name() << "\n";
        std::cout << "Serial: " << info->serialNumber() << "\n";
        std::cout << "Firmware: " << info->firmwareVersion() << "\n";
        std::cout << "Connection: " << info->connectionType() << "\n";

        listColorProfiles(device);

        std::cout << "\nStarting SDK COLOR pipeline...\n";
        ob::Pipeline pipeline(device);
        auto config = std::make_shared<ob::Config>();
        config->enableVideoStream(OB_STREAM_COLOR);
        pipeline.start(config);

        auto enabled = pipeline.getEnabledStreamProfileList();
        std::cout << "Enabled stream count: " << enabled->count() << "\n";
        for(uint32_t i = 0; i < enabled->count(); ++i) {
            auto profile = enabled->getProfile(i);
            std::cout << "  enabled #" << i << " stream=" << static_cast<int>(profile->type())
                      << " fmt=" << static_cast<int>(profile->format());
            if(profile->is<ob::VideoStreamProfile>()) {
                auto video = profile->as<ob::VideoStreamProfile>();
                std::cout << " " << video->width() << "x" << video->height() << "@" << video->fps();
            }
            std::cout << "\n";
        }

        for(int i = 0; i < 50; ++i) {
            auto frames = pipeline.waitForFrames(100);
            if(!frames || !frames->colorFrame()) {
                continue;
            }
            auto color = frames->colorFrame();
            std::cout << "SDK COLOR frame received: " << color->width() << "x" << color->height()
                      << " fmt=" << static_cast<int>(color->format())
                      << " index=" << color->index()
                      << " bytes=" << color->dataSize() << "\n";
            pipeline.stop();
            return 0;
        }

        std::cout << "SDK COLOR pipeline started, but no color frame arrived within 5s.\n";
        pipeline.stop();
        return 3;
    }
    catch(ob::Error &e) {
        std::cerr << "SDK RGB test failed: " << sdkError(e) << "\n";
        return 1;
    }
    catch(const std::exception &e) {
        std::cerr << "SDK RGB test failed: " << e.what() << "\n";
        return 1;
    }
}
