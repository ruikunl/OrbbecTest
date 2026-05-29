#include "libobsensor/ObSensor.hpp"
#include "libobsensor/hpp/Error.hpp"

#include <fstream>
#include <iomanip>
#include <iostream>
#include <memory>
#include <sstream>
#include <string>
#include <vector>

namespace {

std::string sensorName(OBSensorType type) {
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

std::string streamName(OBStreamType type) {
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

std::string fmtIntrinsic(const OBCameraIntrinsic &intr) {
    std::ostringstream out;
    out << std::fixed << std::setprecision(6);
    out << intr.width << "x" << intr.height << " fx=" << intr.fx << " fy=" << intr.fy << " cx=" << intr.cx << " cy=" << intr.cy;
    return out.str();
}

std::string fmtDistortion(const OBCameraDistortion &dist) {
    std::ostringstream out;
    out << std::fixed << std::setprecision(8);
    out << "k1=" << dist.k1 << " k2=" << dist.k2 << " k3=" << dist.k3 << " k4=" << dist.k4 << " k5=" << dist.k5 << " k6=" << dist.k6
        << " p1=" << dist.p1 << " p2=" << dist.p2;
    return out.str();
}

std::string fmtObError(const ob::Error &e) {
    return std::string("function=") + e.getName() + " args=" + e.getArgs() + " message=" + e.getMessage()
           + " type=" + std::to_string(static_cast<int>(e.getExceptionType()));
}

void appendCameraParam(std::vector<std::string> &lines, const std::string &label, const OBCameraParam &param) {
    lines.push_back(label + " depthIntrinsic: " + fmtIntrinsic(param.depthIntrinsic));
    lines.push_back("");
    lines.push_back(label + " rgbIntrinsic: " + fmtIntrinsic(param.rgbIntrinsic));
    lines.push_back("");
    lines.push_back(label + " depthDistortion: " + fmtDistortion(param.depthDistortion));
    lines.push_back("");
    lines.push_back(label + " rgbDistortion: " + fmtDistortion(param.rgbDistortion));
    lines.push_back("");

    std::ostringstream rot;
    rot << std::fixed << std::setprecision(8);
    rot << label << " depthToColor.rot:";
    for(int i = 0; i < 9; ++i) {
        rot << " " << param.transform.rot[i];
    }
    lines.push_back(rot.str());
    lines.push_back("");

    std::ostringstream trans;
    trans << std::fixed << std::setprecision(8);
    trans << label << " depthToColor.trans_mm:";
    for(int i = 0; i < 3; ++i) {
        trans << " " << param.transform.trans[i];
    }
    lines.push_back(trans.str());
    lines.push_back("");
}

void saveText(const std::vector<std::string> &lines, const std::string &path) {
    std::ofstream file(path);
    for(const auto &line : lines) {
        file << line << '\n';
    }
}

}  // namespace

int main(int argc, char **argv) {
    std::vector<std::string> lines;
    lines.push_back("OrbbecSDK v1 intrinsic probe");

    bool metadataOnly = false;
    for(int i = 1; i < argc; ++i) {
        const std::string arg = argv[i];
        if(arg == "--metadata-only" || arg == "--skip-pipeline" || arg == "--no-stream") {
            metadataOnly = true;
        }
    }
    if(metadataOnly) {
        lines.push_back("Mode: metadata-only; pipeline streaming skipped");
    }

    try {
        lines.push_back("SDK version: " + std::to_string(ob::Version::getMajor()) + "." + std::to_string(ob::Version::getMinor()) + "."
                        + std::to_string(ob::Version::getPatch()) + " stage=" + ob::Version::getStageVersion());

        ob::Context ctx;
        auto        devList = ctx.queryDeviceList();
        lines.push_back("Device count: " + std::to_string(devList->deviceCount()));

        for(uint32_t i = 0; i < devList->deviceCount(); ++i) {
            lines.push_back("");
            lines.push_back("Device #" + std::to_string(i));
            auto dev  = devList->getDevice(i);
            auto info = dev->getDeviceInfo();

            std::ostringstream devLine;
            devLine << "name=" << info->name() << " vid=0x" << std::hex << info->vid() << " pid=0x" << info->pid() << std::dec << " uid="
                    << info->uid() << " serial=" << info->serialNumber() << " firmware=" << info->firmwareVersion()
                    << " connection=" << info->connectionType();
            lines.push_back(devLine.str());

            try {
                auto sensors = dev->getSensorList();
                lines.push_back("Sensor count: " + std::to_string(sensors->count()));
                for(uint32_t s = 0; s < sensors->count(); ++s) {
                    auto sensor = sensors->getSensor(s);
                    lines.push_back("  Sensor #" + std::to_string(s) + ": " + sensorName(sensor->type()));

                    try {
                        auto profiles = sensor->getStreamProfileList();
                        lines.push_back("    Profile count: " + std::to_string(profiles->count()));
                        for(uint32_t p = 0; p < profiles->count(); ++p) {
                            auto profile = profiles->getProfile(p);
                            std::ostringstream profileLine;
                            profileLine << "    Profile #" << p << " stream=" << streamName(profile->type()) << " format=" << static_cast<int>(profile->format());
                            if(profile->is<ob::VideoStreamProfile>()) {
                                auto video = profile->as<ob::VideoStreamProfile>();
                                profileLine << " " << video->width() << "x" << video->height() << "@" << video->fps();
                                lines.push_back(profileLine.str());
                                try {
                                    lines.push_back("      intrinsic: " + fmtIntrinsic(video->getIntrinsic()));
                                }
                                catch(ob::Error &e) {
                                    lines.push_back(std::string("      intrinsic SDK error: ") + fmtObError(e));
                                }
                                catch(const std::exception &e) {
                                    lines.push_back(std::string("      intrinsic error: ") + e.what());
                                }
                                try {
                                    lines.push_back("      distortion: " + fmtDistortion(video->getDistortion()));
                                }
                                catch(ob::Error &e) {
                                    lines.push_back(std::string("      distortion SDK error: ") + fmtObError(e));
                                }
                                catch(const std::exception &e) {
                                    lines.push_back(std::string("      distortion error: ") + e.what());
                                }
                            }
                            else {
                                lines.push_back(profileLine.str());
                            }
                        }
                    }
                    catch(ob::Error &e) {
                        lines.push_back(std::string("    profile list SDK error: ") + fmtObError(e));
                    }
                    catch(const std::exception &e) {
                        lines.push_back(std::string("    profile list error: ") + e.what());
                    }
                }
            }
            catch(ob::Error &e) {
                lines.push_back(std::string("Sensor list SDK error: ") + fmtObError(e));
            }
            catch(const std::exception &e) {
                lines.push_back(std::string("Sensor list error: ") + e.what());
            }

            try {
                auto paramList = dev->getCalibrationCameraParamList();
                lines.push_back("Calibration camera param count: " + std::to_string(paramList->count()));
                for(uint32_t p = 0; p < paramList->count(); ++p) {
                    appendCameraParam(lines, "Calibration[" + std::to_string(p) + "]", paramList->getCameraParam(p));
                }
            }
            catch(ob::Error &e) {
                lines.push_back(std::string("Calibration camera param list SDK error: ") + fmtObError(e));
            }
            catch(const std::exception &e) {
                lines.push_back(std::string("Calibration camera param list error: ") + e.what());
            }

            if(metadataOnly) {
                lines.push_back("Pipeline streaming skipped by --metadata-only");
            }
            else {
            try {
                auto pipeline = std::make_shared<ob::Pipeline>(dev);
                auto config   = std::make_shared<ob::Config>();
                try {
                    config->enableVideoStream(OB_STREAM_DEPTH);
                    lines.push_back("Pipeline enabled depth stream");
                }
                catch(ob::Error &e) {
                    lines.push_back(std::string("Pipeline depth enable SDK error: ") + fmtObError(e));
                }
                catch(const std::exception &e) {
                    lines.push_back(std::string("Pipeline depth enable error: ") + e.what());
                }
                try {
                    config->enableVideoStream(OB_STREAM_COLOR);
                    lines.push_back("Pipeline enabled color stream");
                }
                catch(ob::Error &e) {
                    lines.push_back(std::string("Pipeline color enable SDK error: ") + fmtObError(e));
                }
                catch(const std::exception &e) {
                    lines.push_back(std::string("Pipeline color enable error: ") + e.what());
                }

                pipeline->start(config);
                for(int wait = 0; wait < 10; ++wait) {
                    auto frames = pipeline->waitForFrames(1000);
                    if(frames) {
                        lines.push_back("Pipeline received a frameset");
                        break;
                    }
                }
                appendCameraParam(lines, "Pipeline", pipeline->getCameraParam());
                pipeline->stop();
            }
            catch(ob::Error &e) {
                lines.push_back(std::string("Pipeline camera param SDK error: ") + fmtObError(e));
                lines.push_back("Retrying pipeline with depth stream only");
                try {
                    auto depthPipeline = std::make_shared<ob::Pipeline>(dev);
                    auto depthConfig   = std::make_shared<ob::Config>();
                    depthConfig->enableVideoStream(OB_STREAM_DEPTH);
                    depthPipeline->start(depthConfig);
                    bool gotDepth = false;
                    for(int wait = 0; wait < 10; ++wait) {
                        auto frames = depthPipeline->waitForFrames(1000);
                        if(frames && frames->depthFrame()) {
                            auto depthFrame = frames->depthFrame();
                            lines.push_back("Depth-only pipeline received frame: " + std::to_string(depthFrame->width()) + "x"
                                            + std::to_string(depthFrame->height()) + " scale_mm=" + std::to_string(depthFrame->getValueScale()));
                            gotDepth = true;
                            break;
                        }
                    }
                    if(!gotDepth) {
                        lines.push_back("Depth-only pipeline did not receive a frame within 10 seconds");
                    }
                    appendCameraParam(lines, "DepthOnlyPipeline", depthPipeline->getCameraParam());
                    depthPipeline->stop();
                }
                catch(ob::Error &depthOnlyError) {
                    lines.push_back(std::string("Depth-only pipeline SDK error: ") + fmtObError(depthOnlyError));
                }
                catch(const std::exception &depthOnlyError) {
                    lines.push_back(std::string("Depth-only pipeline error: ") + depthOnlyError.what());
                }
            }
            catch(const std::exception &e) {
                lines.push_back(std::string("Pipeline camera param error: ") + e.what());
                lines.push_back("Retrying pipeline with depth stream only");
                try {
                    auto depthPipeline = std::make_shared<ob::Pipeline>(dev);
                    auto depthConfig   = std::make_shared<ob::Config>();
                    depthConfig->enableVideoStream(OB_STREAM_DEPTH);
                    depthPipeline->start(depthConfig);
                    bool gotDepth = false;
                    for(int wait = 0; wait < 10; ++wait) {
                        auto frames = depthPipeline->waitForFrames(1000);
                        if(frames && frames->depthFrame()) {
                            auto depthFrame = frames->depthFrame();
                            lines.push_back("Depth-only pipeline received frame: " + std::to_string(depthFrame->width()) + "x"
                                            + std::to_string(depthFrame->height()) + " scale_mm=" + std::to_string(depthFrame->getValueScale()));
                            gotDepth = true;
                            break;
                        }
                    }
                    if(!gotDepth) {
                        lines.push_back("Depth-only pipeline did not receive a frame within 10 seconds");
                    }
                    appendCameraParam(lines, "DepthOnlyPipeline", depthPipeline->getCameraParam());
                    depthPipeline->stop();
                }
                catch(ob::Error &depthOnlyError) {
                    lines.push_back(std::string("Depth-only pipeline SDK error: ") + fmtObError(depthOnlyError));
                }
                catch(const std::exception &depthOnlyError) {
                    lines.push_back(std::string("Depth-only pipeline error: ") + depthOnlyError.what());
                }
            }
            }
        }
    }
    catch(ob::Error &e) {
        lines.push_back(std::string("SDK error ") + fmtObError(e));
    }
    catch(const std::exception &e) {
        lines.push_back(std::string("std::exception: ") + e.what());
    }

    saveText(lines, "outputs/orbbec_intrinsics_v1.txt");
    for(const auto &line : lines) {
        std::cout << line << std::endl;
    }
    std::cout << "Text saved to outputs/orbbec_intrinsics_v1.txt" << std::endl;
    return 0;
}
