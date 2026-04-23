//
// Anti-spoofing JNI bridge for Flutter/ALAMS
// Adapted from Silent-Face-Anti-Spoofing-APK
//

#include <android/asset_manager_jni.h>
#include <jni.h>
#include <string>
#include <vector>
#include "live/live.h"
#include "img_process.h"
#include "android_log.h"

static Live* g_live = nullptr;

extern "C" {

JNIEXPORT jint JNICALL
Java_com_example_alams_AntiSpoofEngine_nativeInit(JNIEnv *env, jobject instance, jobject asset_manager) {
    if (g_live != nullptr) {
        delete g_live;
    }
    g_live = new Live();

    AAssetManager* mgr = AAssetManager_fromJava(env, asset_manager);

    // Read config.json from assets
    AAsset* configAsset = AAssetManager_open(mgr, "live/config.json", AASSET_MODE_BUFFER);
    if (!configAsset) {
        LOG_ERR("Failed to open live/config.json");
        return -1;
    }

    const char* configData = (const char*)AAsset_getBuffer(configAsset);
    off_t configLen = AAsset_getLength(configAsset);
    std::string configStr(configData, configLen);
    AAsset_close(configAsset);

    // Simple JSON parsing for the config array
    std::vector<ModelConfig> configs;

    // Parse model entries (simple parser for known format)
    size_t pos = 0;
    while ((pos = configStr.find("\"name\"", pos)) != std::string::npos) {
        ModelConfig cfg;

        // Parse name
        size_t nameStart = configStr.find("\"", pos + 6) + 1;
        size_t nameEnd = configStr.find("\"", nameStart);
        cfg.name = configStr.substr(nameStart, nameEnd - nameStart);

        // Parse org_resize
        size_t orgResizePos = configStr.find("\"org_resize\"", pos);
        if (orgResizePos != std::string::npos && orgResizePos < configStr.find("}", pos)) {
            size_t valStart = configStr.find(":", orgResizePos) + 1;
            std::string val = configStr.substr(valStart, 5);
            cfg.org_resize = (val.find("true") != std::string::npos);
        }

        // Parse scale
        size_t scalePos = configStr.find("\"scale\"", pos);
        if (scalePos != std::string::npos) {
            size_t valStart = configStr.find(":", scalePos) + 1;
            cfg.scale = std::stof(configStr.substr(valStart));
        }

        // Parse shift_x
        size_t shiftXPos = configStr.find("\"shift_x\"", pos);
        if (shiftXPos != std::string::npos) {
            size_t valStart = configStr.find(":", shiftXPos) + 1;
            cfg.shift_x = std::stof(configStr.substr(valStart));
        }

        // Parse shift_y
        size_t shiftYPos = configStr.find("\"shift_y\"", pos);
        if (shiftYPos != std::string::npos) {
            size_t valStart = configStr.find(":", shiftYPos) + 1;
            cfg.shift_y = std::stof(configStr.substr(valStart));
        }

        // Parse height
        size_t heightPos = configStr.find("\"height\"", pos);
        if (heightPos != std::string::npos) {
            size_t valStart = configStr.find(":", heightPos) + 1;
            cfg.height = std::stoi(configStr.substr(valStart));
        }

        // Parse width
        size_t widthPos = configStr.find("\"width\"", pos);
        if (widthPos != std::string::npos) {
            size_t valStart = configStr.find(":", widthPos) + 1;
            cfg.width = std::stoi(configStr.substr(valStart));
        }

        configs.push_back(cfg);
        pos = nameEnd + 1;
    }

    LOG_INFO("Parsed %d model configs", (int)configs.size());
    for (int i = 0; i < configs.size(); i++) {
        LOG_INFO("Model %d: name=%s, scale=%.1f, size=%dx%d",
                 i, configs[i].name.c_str(), configs[i].scale, configs[i].width, configs[i].height);
    }

    return g_live->LoadModel(mgr, configs);
}


JNIEXPORT jfloat JNICALL
Java_com_example_alams_AntiSpoofEngine_nativeDetect(JNIEnv *env, jobject instance,
        jbyteArray nv21Data, jint width, jint height, jint orientation,
        jint faceLeft, jint faceTop, jint faceRight, jint faceBottom) {

    if (g_live == nullptr) {
        return -1.0f;
    }

    jbyte *data = env->GetByteArrayElements(nv21Data, nullptr);

    cv::Mat bgr;
    Yuv420sp2bgr(reinterpret_cast<unsigned char *>(data), width, height, orientation, bgr);

    FaceBox faceBox;
    faceBox.x1 = faceLeft;
    faceBox.y1 = faceTop;
    faceBox.x2 = faceRight;
    faceBox.y2 = faceBottom;

    float confidence = g_live->Detect(bgr, faceBox);
    env->ReleaseByteArrayElements(nv21Data, data, 0);

    return confidence;
}


JNIEXPORT void JNICALL
Java_com_example_alams_AntiSpoofEngine_nativeDestroy(JNIEnv *env, jobject instance) {
    if (g_live != nullptr) {
        delete g_live;
        g_live = nullptr;
    }
}

}
