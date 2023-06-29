@vertex
#version 330 core

in vec2 in_position;
in vec2 in_uv;

out vec2 pass_uv;

uniform mat4 u_projection;

void main(void) {
    gl_Position = u_projection * vec4(in_position, 0.0, 1.0);
    pass_uv = in_uv;
}

@fragment
#version 330 core

in vec2 pass_uv;

out vec4 out_color;

uniform sampler2D t_texture;
uniform vec4 u_foreground;
uniform vec4 u_background;

const float c_gamma = 1.0;
const float c_inverse_gamma = 1.0 / c_gamma;

vec4 pow4(vec4 _input, float exponent) {
    vec4 _output = vec4(pow(_input.x, exponent),
                        pow(_input.y, exponent),
                        pow(_input.z, exponent),
                        pow(_input.w, exponent));
    return _output;
}

void main(void) {
#if 1
    // LCD SUBFILTERING
    vec4 texture_sample = texture2D(t_texture, pass_uv);
    // Convert the gamma encoded color values into linear space
    vec4 linear_foreground = pow4(u_foreground, c_gamma);
    vec4 linear_background = pow4(u_background, c_gamma);
    
    // Blend between the background color and the pixel. Since the outputted pixel does not have
    // an actual alpha value, we need to premultiply the alpha of both the fore- and the background
    // color here to produce correct results if at least one of them is transparent.
    float r = texture_sample.r * linear_foreground.r * linear_foreground.a + (1.0 - texture_sample.r) * linear_background.r * linear_background.a;
    float g = texture_sample.g * linear_foreground.g * linear_foreground.a + (1.0 - texture_sample.g) * linear_background.g * linear_background.a;
    float b = texture_sample.b * linear_foreground.b * linear_foreground.a + (1.0 - texture_sample.b) * linear_background.b * linear_background.a;

    // Gamma encode the resuling texel
    out_color = pow4(vec4(r, g, b, 1), c_inverse_gamma);
    //out_color = vec4(a, 0, 0, 1);
#else
    // NO LCD SUBFILTERING
    float alpha = texture2D(t_texture, pass_uv).r;
    out_color = vec4(u_color, alpha);
#endif
}
