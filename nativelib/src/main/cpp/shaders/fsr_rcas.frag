#version 300 es
precision highp float;
in vec2 vTexCoord;
uniform sampler2D uInputTexture;
uniform float uSharpness;  // 0.0 = 最大锐化, 值越大锐化越弱
uniform int uIsHdr;        // HDR 模式标志（BT.2020 亮度系数）
out vec4 outColor;

void main() {
    vec3 lumaCoeff = (uIsHdr == 1) ? vec3(0.2627, 0.6780, 0.0593) : vec3(0.299, 0.587, 0.114);
    vec2 texSize = vec2(textureSize(uInputTexture, 0));
    vec2 texelSize = 1.0 / texSize;

    // 十字采样 5 tap
    vec3 e = texture(uInputTexture, vTexCoord).rgb;
    vec3 b = texture(uInputTexture, vTexCoord + vec2( 0, -1) * texelSize).rgb;
    vec3 d = texture(uInputTexture, vTexCoord + vec2(-1,  0) * texelSize).rgb;
    vec3 f = texture(uInputTexture, vTexCoord + vec2( 1,  0) * texelSize).rgb;
    vec3 h = texture(uInputTexture, vTexCoord + vec2( 0,  1) * texelSize).rgb;

    // 亮度（近似 luma*2，与 AMD 原版一致：0.5*B + 0.5*R + G）
    float bL = dot(b, lumaCoeff);
    float dL = dot(d, lumaCoeff);
    float eL = dot(e, lumaCoeff);
    float fL = dot(f, lumaCoeff);
    float hL = dot(h, lumaCoeff);

    // 噪声检测
    float nz = 0.25 * (bL + dL + fL + hL) - eL;
    float range = max(max(bL, max(dL, eL)), max(fL, hL))
                - min(min(bL, min(dL, eL)), min(fL, hL));
    nz = clamp(abs(nz) / max(range, 1e-5), 0.0, 1.0);
    nz = 1.0 - 0.5 * nz;

    // 邻域极值
    float mn4R = min(min(b.r, d.r), min(f.r, h.r));
    float mn4G = min(min(b.g, d.g), min(f.g, h.g));
    float mn4B = min(min(b.b, d.b), min(f.b, h.b));
    float mx4R = max(max(b.r, d.r), max(f.r, h.r));
    float mx4G = max(max(b.g, d.g), max(f.g, h.g));
    float mx4B = max(max(b.b, d.b), max(f.b, h.b));

    // 求解最大不截断的锐化权重（AMD 原版 RCAS 算法）
    // hitMin = min(mn4, e) / (4*mx4)          → 正值
    // hitMax = (1 - max(mx4, e)) / (4*mn4-4)  → 负值
    // lobe = max(-hitMin, hitMax)              → 负值（锐化权重）
    vec2 peakC = vec2(1.0, -4.0);
    float hitMinR = min(mn4R, e.r) / max(4.0 * mx4R, 1e-5);
    float hitMinG = min(mn4G, e.g) / max(4.0 * mx4G, 1e-5);
    float hitMinB = min(mn4B, e.b) / max(4.0 * mx4B, 1e-5);
    float hitMaxR = (peakC.x - max(mx4R, e.r)) / min(4.0 * mn4R + peakC.y, -1e-5);
    float hitMaxG = (peakC.x - max(mx4G, e.g)) / min(4.0 * mn4G + peakC.y, -1e-5);
    float hitMaxB = (peakC.x - max(mx4B, e.b)) / min(4.0 * mn4B + peakC.y, -1e-5);
    float lobeR = max(-hitMinR, hitMaxR);
    float lobeG = max(-hitMinG, hitMaxG);
    float lobeB = max(-hitMinB, hitMaxB);

    // 限制锐化强度（lobe 为负值）
    float limit = 0.25 - 1.0 / 16.0;
    float lobe = max(-limit, min(max(max(lobeR, lobeG), lobeB), 0.0));

    // 应用锐度控制
    float sharp = exp2(-uSharpness);
    lobe *= sharp * nz;

    float rcpW = 1.0 / (4.0 * lobe + 1.0);
    outColor = vec4((lobe * b + lobe * d + lobe * h + lobe * f + e) * rcpW, 1.0);
}
