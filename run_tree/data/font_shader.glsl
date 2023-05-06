@vertex
#version 330 core

in vec2 in_position;

out vec2 pass_uv;

uniform vec2 u_scale;
uniform vec2 u_position;
uniform mat4 u_projection;

void main(void) {
    gl_Position = u_projection * vec4(in_position * u_scale + u_position, 0.0, 1.0);
    pass_uv = in_position;
}

@fragment
#version 330 core

#define USE_LCD_SAMPLING false

in vec2 pass_uv;

out vec4 out_color;

uniform sampler2D t_texture;
uniform vec3 u_color;

void main(void) {
#if USE_LCD_SAMPLING
    vec4 _sample = texture2D(t_texture, pass_uv);
    out_color = vec4(_sample.rgb * u_color, _sample.a);
#else
    float alpha = texture2D(t_texture, pass_uv).r;
    out_color = vec4(u_color, alpha);
#endif
}
