#version 300 es
#extension GL_OES_EGL_image_external_essl3 : require

precision highp float;

in vec2 vTexCoord;
uniform samplerExternalOES uTexture;
uniform vec2 uTexelSize;
uniform float uTimePhase;
uniform int uEnableFilter;
uniform int uHdrMode;
uniform int uSdrToHdr;
uniform float uSdrPeakNits;
uniform float uSdrSaturation;
uniform float uSdrContrast;

out vec4 outColor;

// PQ (Perceptual Quantizer, SMPTE ST 2084) 常量
const float PQ_M1 = 0.1593017578125;
const float PQ_M2 = 78.84375;
const float PQ_C1 = 0.8359375;
const float PQ_C2 = 18.8515625;
const float PQ_C3 = 18.6875;
const float MAX_NITS = 10000.0;

// HLG (Hybrid Log-Gamma, ARIB STD-B67) 常量
const float HLG_A = 0.17883277;
const float HLG_B = 0.28466892;
const float HLG_C = 0.55991073;

// =========================================================================
// 传递函数：PQ ↔ 线性
// =========================================================================
vec3 pq_to_lin(vec3 pq) {
    vec3 p = pow(clamp(pq, 0.0, 1.0), vec3(1.0 / PQ_M2));
    return pow(max(p - PQ_C1, 0.0) / max(PQ_C2 - PQ_C3 * p, 1e-6), vec3(1.0 / PQ_M1));
}

vec3 lin_to_pq(vec3 lin) {
    vec3 lp = pow(max(lin, 0.0), vec3(PQ_M1));
    return pow((PQ_C1 + PQ_C2 * lp) / (1.0 + PQ_C3 * lp), vec3(PQ_M2));
}

// =========================================================================
// 传递函数：HLG ↔ 线性
// =========================================================================
vec3 hlg_to_lin(vec3 e) {
    vec3 s = clamp(e, 0.0, 1.0);
    vec3 mask = step(0.5, s);
    return mix(s * s / 3.0,
               (exp((s - HLG_C) / HLG_A) + HLG_B) / 12.0,
               mask);
}

vec3 lin_to_hlg(vec3 l) {
    l = max(l, 0.0);
    vec3 mask = step(0.08333333, l);
    return mix(sqrt(3.0 * l),
               HLG_A * log(12.0 * l - HLG_B) + HLG_C,
               mask);
}

// BT.2020 亮度系数
float luma_2020(vec3 c) { return dot(c, vec3(0.2627, 0.6780, 0.0593)); }

// =========================================================================
// Interleaved Gradient Noise (Jorge Jimenez, 2014)
// 非周期、计算廉价、频谱优于 Bayer 有序抖动
// =========================================================================
float IGN(vec2 p) {
    return fract(52.9829189 * fract(0.06711056 * p.x + 0.00583715 * p.y));
}

// =========================================================================
// Luma-Preserving Mapper (inspired by AMD FidelityFX LPM)
// 输入/输出：绝对亮度 (nits)
// =========================================================================

// BT.709 → BT.2020 线性色域转换矩阵 (column-major)
const mat3 MAT_709_TO_2020 = mat3(
    0.6274, 0.0691, 0.0164,
    0.3293, 0.9195, 0.0880,
    0.0433, 0.0114, 0.8956
);

// SDR→HDR 亮度保持映射 + 高光去饱和
// sdrRef: SDR 参考白 (nits), peakNits: HDR 峰值, sat: 饱和度倍率
vec3 lpmExpand(vec3 nitsIn, float sdrRef, float peakNits, float sat) {
    vec3 lw = vec3(0.2627, 0.6780, 0.0593);
    float Yin = dot(nitsIn, lw);
    // 极暗或已超 SDR 参考范围 → 不处理
    if (Yin < 0.01 || Yin >= sdrRef * 1.1) return nitsIn;

    // 指数映射：暗部线性扩展，高光柔和肩部趋近 peak
    float normY = Yin / sdrRef;
    float k = log(peakNits / sdrRef + 1.0);
    float Yout = peakNits * (1.0 - exp(-k * normY)) / (1.0 - exp(-k));

    // 亮度保持 RGB 等比缩放（保持色度比不变）
    vec3 nitsOut = nitsIn * (Yout / Yin);

    // 高光去饱和（模拟 Hunt 效应 / LPM crosstalk）
    // 人眼在高亮度下色彩敏感度下降，自然呈现去饱和
    float ct = smoothstep(peakNits * 0.5, peakNits, Yout);
    nitsOut = mix(nitsOut, vec3(Yout), ct * 0.3);

    // 用户饱和度控制
    float Ys = dot(nitsOut, lw);
    nitsOut = max(Ys + (nitsOut - Ys) * sat, 0.0);

    return min(nitsOut, peakNits);
}

void main() {
    vec4 tex = texture(uTexture, vTexCoord);

    // SDR 内容 + HDR 显示面 → LPM 亮度保持映射 + BT.709→2020 + PQ 编码
    if (uSdrToHdr == 1 && uHdrMode == 0) {
        vec3 linear = pow(max(tex.rgb, 0.0), vec3(2.2));
        // BT.709 → BT.2020 色域转换 + SDR 100 nits 参考 → HDR 扩展
        vec3 linear2020 = MAT_709_TO_2020 * max(linear, vec3(0.0));
        vec3 hdrNits = lpmExpand(linear2020 * 100.0, 100.0, uSdrPeakNits, uSdrSaturation);
        outColor = vec4(lin_to_pq(hdrNits / MAX_NITS), tex.a);
        return;
    }

    // SDR 模式且无 SDR→HDR → 直通
    if (uHdrMode == 0) {
        outColor = tex;
        return;
    }

    // ===== HLG SDR-in-HDR: S-curve 逆色调映射 =====
    // S-curve：f(x) = x + maxBoost * x³/(1+x³)，暗部不动、高光扩展
    if (uSdrToHdr == 1 && uEnableFilter == 0 && uHdrMode == 2) {
        vec3 hlg = tex.rgb;
        vec3 lw = vec3(0.2627, 0.6780, 0.0593);
        float Yhlg = dot(hlg, lw);
        if (Yhlg > 0.001 && Yhlg < 0.99) {
            float maxBoost = (uSdrPeakNits - 203.0) / 1000.0;
            maxBoost = max(maxBoost, 0.0);

            // S-curve 全局增益
            vec3 x = hlg;
            vec3 x3 = x * x * x;
            vec3 boost = maxBoost * x3 / (1.0 + x3);
            hlg = hlg + boost;

            // 对比度（power-curve，感知均匀）
            if (uSdrContrast != 1.0) {
                vec3 centered = 2.0 * hlg - 1.0;
                vec3 absc = abs(centered);
                vec3 adj = sign(centered) * pow(max(absc, 1e-7), vec3(1.0 / uSdrContrast));
                hlg = clamp(0.5 + 0.5 * adj, 0.0, 1.0);
            }

            // 饱和度调整
            float Yout = dot(hlg, lw);
            hlg = Yout + (hlg - Yout) * uSdrSaturation;
            hlg = clamp(hlg, 0.0, 1.0);
        }
        outColor = vec4(hlg, tex.a);
        return;
    }

    // 亮区提前退出（> 0.4 编码值 ≈ > 40 nits），无需暗区处理
    // 但 SDR→HDR 增强需要处理全亮度范围，不能提前跳过
    if (uSdrToHdr == 0 && uEnableFilter == 1 && max(tex.r, max(tex.g, tex.b)) > 0.4) {
        outColor = tex;
        return;
    }

    // ----- IGN 噪声采样（替代 Bayer/蓝噪声纹理，消除模式切换闪烁）-----
    vec2 pixelId = floor(vTexCoord / max(uTexelSize, 1e-5));
    vec2 frameOffset = vec2(
        fract(sin(uTimePhase * 123.456) * 43758.545),
        fract(cos(uTimePhase * 789.012) * 32145.678)) * 4096.0;
    float noise  = IGN(pixelId + frameOffset);
    float noise2 = IGN(pixelId + frameOffset + vec2(17.0, 31.0));

    // ----- 负值重分配（防止解码器溢出） -----
    vec3 rgb = min(tex.rgb, 1.0);
    float minCh = min(min(rgb.r, rgb.g), rgb.b);
    if (minCh < 0.0) {
        float Y = luma_2020(rgb);
        rgb = (Y <= 0.0) ? vec3(0.0) : mix(vec3(Y), rgb, Y / (Y - minCh));
    }

    // ----- 解码到线性空间 -----
    vec3 lin = (uHdrMode == 1) ? pq_to_lin(rgb) : hlg_to_lin(rgb);

    // ----- SDR-in-HDR 动态范围增强 (LPM) -----
    if (uSdrToHdr == 1) {
        if (uHdrMode == 1) {
            // PQ 模式：LPM 扩展 SDR 范围 (0-203 nits) 到 HDR 峰值
            // 已是 BT.2020，无需色域转换
            vec3 nitsExpanded = lpmExpand(lin * MAX_NITS, 203.0, uSdrPeakNits, uSdrSaturation);
            lin = nitsExpanded / MAX_NITS;
        } else {
            // HLG 模式：直接在 HLG 编码域增强（避免线性域精度问题）
            // HLG 编码已经是感知均匀的，直接操作更安全
            float Yhlg = dot(rgb, vec3(0.2627, 0.6780, 0.0593));
            if (Yhlg > 0.001) {
                // 温和提升：峰值500nits → 1.37x, 1000nits → 2.0x
                float peakScale = 1.0 + (uSdrPeakNits - 203.0) / 800.0;
                peakScale = max(peakScale, 1.0);
                // 逆 Reinhard 在 HLG 编码域
                float expanded = Yhlg * peakScale / (1.0 + Yhlg * (peakScale - 1.0));
                rgb = rgb * (expanded / Yhlg);
                rgb = min(rgb, 1.0);
            }
            // 重新解码增强后的 HLG 值到线性域（供后续暗区滤镜使用）
            lin = hlg_to_lin(rgb);
        }
    }

    float Y = luma_2020(lin);
    float nits = Y * MAX_NITS;

    // 仅 SDR→HDR 增强、不需要暗区滤镜 → 直接重编码输出
    if (uEnableFilter == 0) {
        outColor = vec4(
            (uHdrMode == 1) ? lin_to_pq(lin) : lin_to_hlg(lin),
            tex.a);
        return;
    }

    // HLG 暗区抖动不适用：nits = lin * 10000 仅对 PQ 绝对亮度正确，
    // HLG 场景参考光无法映射到 OLED 标定阶梯。直接重编码输出。
    if (uHdrMode == 2) {
        outColor = vec4(lin_to_hlg(lin), tex.a);
        return;
    }

    // ----- 暗区 PDM 抖动 (0–10 nits) -----
    // 用 IGN 噪声在安全亮度阶梯间做概率性插值
    // 补偿 OLED 面板最低亮度高于 PQ 曲线的缺陷
    //
    // edge 边界 = 面板标定的"PQ 标准亮度→实际输出亮度" 映射节点
    // 面板无法显示 edge 之间的连续灰阶，通过 0/1 抖动模拟中间亮度
    // 适配设备：MatePad Pro 12.2 (实测标定)
    vec3 result = lin;
    if (nits > 1e-7 && nits <= 10.0) {
        // 8% 亮度微扰消除阶梯边界
        float jNits = clamp(nits + (noise2 - 0.5) * nits * 0.08, 1e-7, 10.0);

        // 11 档安全亮度阶梯（二分法查找，3-4 次比较替代线性扫描）
        // lo/hi = nits 阈值对，由噪声概率选择
        float lo, hi, eLo, eHi;
        if (jNits <= 1.25) {
            if (jNits <= 0.5625) {
                if (jNits <= 0.375) {
                    lo = 0.0;    hi = 0.0825; eLo = 0.0;    eHi = 0.375;
                } else {
                    lo = 0.0825; hi = 0.225;  eLo = 0.375;  eHi = 0.5625;
                }
            } else {
                if (jNits <= 0.75) {
                    lo = 0.225;  hi = 0.33;   eLo = 0.5625; eHi = 0.75;
                } else if (jNits <= 1.0) {
                    lo = 0.33;   hi = 0.55;   eLo = 0.75;   eHi = 1.0;
                } else {
                    lo = 0.55;   hi = 0.775;  eLo = 1.0;    eHi = 1.25;
                }
            }
        } else {
            if (jNits <= 3.175) {
                if (jNits <= 1.875) {
                    lo = 0.775;  hi = 1.2;    eLo = 1.25;   eHi = 1.875;
                } else if (jNits <= 2.5) {
                    lo = 1.2;    hi = 1.7;    eLo = 1.875;  eHi = 2.5;
                } else {
                    lo = 1.7;    hi = 2.55;   eLo = 2.5;    eHi = 3.175;
                }
            } else {
                if (jNits <= 5.0) {
                    lo = 2.55;   hi = 3.6;    eLo = 3.175;  eHi = 5.0;
                } else if (jNits <= 7.5) {
                    lo = 3.6;    hi = 6.6;    eLo = 5.0;    eHi = 7.5;
                } else {
                    lo = 6.6;   hi = 10.0;    eLo = 7.5;    eHi = 10.0;
                }
            }
        }
        float mapped = mix(lo, hi, step(noise, (jNits - eLo) / max(eHi - eLo, 1e-7)));

        result = lin * (mapped / max(nits, 1e-7));
    } else if (nits <= 1e-7) {
        result = vec3(0.0);
    }

    // ----- Hunt 效应色度补偿 -----
    // 低亮度下人眼色彩感知衰减，适度增强色度
    float Yout = luma_2020(result);
    float nitsOut = Yout * MAX_NITS;
    float t = clamp((nitsOut - 0.1) * 0.101, 0.0, 1.0);
    float boost = 1.0 + 0.35 * (1.0 - t * t * (3.0 - 2.0 * t));

    vec3 chroma = result - Yout;
    // 安全限幅：防止色度增强导致负值
    float dR = Yout - result.r, dG = Yout - result.g, dB = Yout - result.b;
    float safeLimit = 0.99 * min(
        min((dR > 1e-6) ? Yout / dR : 10.0, (dG > 1e-6) ? Yout / dG : 10.0),
        (dB > 1e-6) ? Yout / dB : 10.0);
    result = Yout + chroma * min(boost, safeLimit);
    result = max(result, 0.0);

    // ----- 重编码 -----
    outColor = vec4(
        (uHdrMode == 1) ? lin_to_pq(result) : lin_to_hlg(result),
        tex.a);
}
