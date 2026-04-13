#version 300 es
precision highp float;
in vec2 vTexCoord;
uniform sampler2D uInputTexture;
uniform vec2 uInputSize;      // 输入纹理尺寸
uniform vec2 uOutputSize;     // 输出目标尺寸
uniform int uIsHdr;           // HDR 模式标志（BT.2020 亮度系数）
out vec4 outColor;

// 近似 Lanczos2 核（无 sin/rcp/sqrt）
// (25/16 * (2/5*d²-1)² - (25/16-1)) * (1/4*d²-1)²
float FsrEasuW(float d2, float lob, float clp) {
    d2 = min(d2, clp);
    float wB = (2.0/5.0) * d2 - 1.0;
    float wA = lob * d2 - 1.0;
    wB *= wB;
    wA *= wA;
    wB = (25.0/16.0) * wB - (25.0/16.0 - 1.0);
    return wB * wA;
}

void main() {
    // 近似亮度：luma*2 = 0.5*B + 0.5*R + G（与 AMD 原版一致，节省乘法）
    vec3 lumaCoeff = vec3(0.5, 1.0, 0.5);

    // 从输出空间映射到输入空间
    vec2 inputTexelSize = 1.0 / uInputSize;
    vec2 srcPixel = vTexCoord * uInputSize - 0.5;
    vec2 fp = floor(srcPixel);
    vec2 pp = srcPixel - fp;
    vec2 base = (fp + 0.5) * inputTexelSize;

    // 采样 12-tap 十字核
    //    b c
    //  e f g h
    //  i j k l
    //    n o
    vec3 b = texture(uInputTexture, base + vec2( 0, -1) * inputTexelSize).rgb;
    vec3 c = texture(uInputTexture, base + vec2( 1, -1) * inputTexelSize).rgb;
    vec3 e = texture(uInputTexture, base + vec2(-1,  0) * inputTexelSize).rgb;
    vec3 f = texture(uInputTexture, base).rgb;
    vec3 g = texture(uInputTexture, base + vec2( 1,  0) * inputTexelSize).rgb;
    vec3 h = texture(uInputTexture, base + vec2( 2,  0) * inputTexelSize).rgb;
    vec3 i = texture(uInputTexture, base + vec2(-1,  1) * inputTexelSize).rgb;
    vec3 j = texture(uInputTexture, base + vec2( 0,  1) * inputTexelSize).rgb;
    vec3 k = texture(uInputTexture, base + vec2( 1,  1) * inputTexelSize).rgb;
    vec3 l = texture(uInputTexture, base + vec2( 2,  1) * inputTexelSize).rgb;
    vec3 n = texture(uInputTexture, base + vec2( 0,  2) * inputTexelSize).rgb;
    vec3 o = texture(uInputTexture, base + vec2( 1,  2) * inputTexelSize).rgb;

    // 近似亮度（luma*2）
    float bL = dot(b, lumaCoeff);
    float cL = dot(c, lumaCoeff);
    float eL = dot(e, lumaCoeff);
    float fL = dot(f, lumaCoeff);
    float gL = dot(g, lumaCoeff);
    float hL = dot(h, lumaCoeff);
    float iL = dot(i, lumaCoeff);
    float jL = dot(j, lumaCoeff);
    float kL = dot(k, lumaCoeff);
    float lL = dot(l, lumaCoeff);
    float nL = dot(n, lumaCoeff);
    float oL = dot(o, lumaCoeff);

    // 方向检测：4 个双线性位置累加方向和长度
    //   (0): b,e,f,g,j    (1): c,f,g,h,k
    //   (2): f,i,j,k,n    (3): g,j,k,l,o
    vec2 dir = vec2(0.0);
    float len = 0.0;

    // --- Set 0: biS ---
    {
        float w = (1.0 - pp.x) * (1.0 - pp.y);
        float dc = gL - fL; float cb = fL - eL;
        float lenX = max(abs(dc), abs(cb));
        lenX = (lenX > 0.0) ? 1.0 / lenX : 0.0;
        float dX = gL - eL;
        dir.x += dX * w;
        float sX = clamp(abs(dX) * lenX, 0.0, 1.0); sX *= sX; len += sX * w;
        float ec = jL - fL; float ca = fL - bL;
        float lenY = max(abs(ec), abs(ca));
        lenY = (lenY > 0.0) ? 1.0 / lenY : 0.0;
        float dY = jL - bL;
        dir.y += dY * w;
        float sY = clamp(abs(dY) * lenY, 0.0, 1.0); sY *= sY; len += sY * w;
    }
    // --- Set 1: biT ---
    {
        float w = pp.x * (1.0 - pp.y);
        float dc = hL - gL; float cb = gL - fL;
        float lenX = max(abs(dc), abs(cb));
        lenX = (lenX > 0.0) ? 1.0 / lenX : 0.0;
        float dX = hL - fL;
        dir.x += dX * w;
        float sX = clamp(abs(dX) * lenX, 0.0, 1.0); sX *= sX; len += sX * w;
        float ec = kL - gL; float ca = gL - cL;
        float lenY = max(abs(ec), abs(ca));
        lenY = (lenY > 0.0) ? 1.0 / lenY : 0.0;
        float dY = kL - cL;
        dir.y += dY * w;
        float sY = clamp(abs(dY) * lenY, 0.0, 1.0); sY *= sY; len += sY * w;
    }
    // --- Set 2: biU ---
    {
        float w = (1.0 - pp.x) * pp.y;
        float dc = kL - jL; float cb = jL - iL;
        float lenX = max(abs(dc), abs(cb));
        lenX = (lenX > 0.0) ? 1.0 / lenX : 0.0;
        float dX = kL - iL;
        dir.x += dX * w;
        float sX = clamp(abs(dX) * lenX, 0.0, 1.0); sX *= sX; len += sX * w;
        float ec = nL - jL; float ca = jL - fL;
        float lenY = max(abs(ec), abs(ca));
        lenY = (lenY > 0.0) ? 1.0 / lenY : 0.0;
        float dY = nL - fL;
        dir.y += dY * w;
        float sY = clamp(abs(dY) * lenY, 0.0, 1.0); sY *= sY; len += sY * w;
    }
    // --- Set 3: biV ---
    {
        float w = pp.x * pp.y;
        float dc = lL - kL; float cb = kL - jL;
        float lenX = max(abs(dc), abs(cb));
        lenX = (lenX > 0.0) ? 1.0 / lenX : 0.0;
        float dX = lL - jL;
        dir.x += dX * w;
        float sX = clamp(abs(dX) * lenX, 0.0, 1.0); sX *= sX; len += sX * w;
        float ec = oL - kL; float ca = kL - gL;
        float lenY = max(abs(ec), abs(ca));
        lenY = (lenY > 0.0) ? 1.0 / lenY : 0.0;
        float dY = oL - gL;
        dir.y += dY * w;
        float sY = clamp(abs(dY) * lenY, 0.0, 1.0); sY *= sY; len += sY * w;
    }

    // 归一化方向
    float dirR = dir.x * dir.x + dir.y * dir.y;
    bool zro = dirR < (1.0 / 32768.0);
    dirR = inversesqrt(max(dirR, 1.0 / 32768.0));
    dirR = zro ? 1.0 : dirR;
    dir.x = zro ? 1.0 : dir.x;
    dir *= dirR;

    // 将 len 转换到 {0,1} 并平方
    len *= 0.5;
    len *= len;

    // 沿边缘拉伸核
    float stretch = (dir.x * dir.x + dir.y * dir.y) / max(abs(dir.x), abs(dir.y));
    vec2 len2 = vec2(1.0 + (stretch - 1.0) * len, 1.0 - 0.5 * len);

    // 负瓣参数
    float lob = 0.5 + ((0.25 - 0.04) - 0.5) * len;
    float clp = 1.0 / lob;

    // 邻域极值（f,g,j,k 最近 4 像素）
    vec3 minC = min(min(f, g), min(j, k));
    vec3 maxC = max(max(f, g), max(j, k));

    // 12-tap 累加（旋转+各向异性）
    vec3 aC = vec3(0.0);
    float aW = 0.0;

    #define TAP(px,py,col) { \
        vec2 ofs = vec2(px, py) - pp; \
        float vx = ofs.x * dir.x + ofs.y * dir.y; \
        float vy = ofs.x * (-dir.y) + ofs.y * dir.x; \
        vx *= len2.x; vy *= len2.y; \
        float d2 = vx * vx + vy * vy; \
        float tw = FsrEasuW(d2, lob, clp); \
        aC += col * tw; aW += tw; \
    }

    TAP( 0.0, -1.0, b)  // b
    TAP( 1.0, -1.0, c)  // c
    TAP(-1.0,  0.0, e)  // e
    TAP( 0.0,  0.0, f)  // f
    TAP( 1.0,  0.0, g)  // g
    TAP( 2.0,  0.0, h)  // h
    TAP(-1.0,  1.0, i)  // i
    TAP( 0.0,  1.0, j)  // j
    TAP( 1.0,  1.0, k)  // k
    TAP( 2.0,  1.0, l)  // l
    TAP( 0.0,  2.0, n)  // n
    TAP( 1.0,  2.0, o)  // o

    #undef TAP

    // 归一化并夹钳（消除振铃）
    vec3 result = aC / max(aW, 1e-5);
    outColor = vec4(clamp(result, minC, maxC), 1.0);
}
