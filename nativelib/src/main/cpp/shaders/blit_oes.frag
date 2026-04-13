#version 300 es
#extension GL_OES_EGL_image_external_essl3 : require
precision mediump float;
in vec2 vTexCoord;
uniform samplerExternalOES uTexture;
out vec4 outColor;
void main() {
    outColor = texture(uTexture, vTexCoord);
}
