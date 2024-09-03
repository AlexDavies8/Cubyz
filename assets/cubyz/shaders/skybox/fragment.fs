#version 330 

layout (location=0) out vec4 fragColor;

in vec3 eyeDirection;

uniform sampler2D skyGradient;
// uniform sampler2D sun;
// uniform sampler2D moon;
// uniform sampler2D stars;
uniform float dayCycle;

void main() {
	vec4 skyColor = texture(skyGradient, vec2(dayCycle, abs(eyeDirection.z * 0.5 + 0.5)));

	fragColor = skyColor;
}