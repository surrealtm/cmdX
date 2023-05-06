@vertex
#version 330 core

in vec2 in_position;

uniform vec2 u_scale;
uniform vec2 u_position;
uniform mat4 u_projection;

void main(void) {
    gl_Position = u_projection * vec4(in_position * u_scale + u_position, 0.0, 1.0);
}

@fragment
#version 330 core

out vec4 out_color;

uniform vec4 u_color;

void main(void) {
    out_color = u_color;
}
