#version 330 

layout (location=0) out vec4 fragColor;

in vec3 eyeDirection;

#define PI 3.14159
#define HALF_PI 1.57080

uniform sampler2D skyGradient;
uniform sampler2D moon;
uniform sampler2D stars;
uniform float sunRadius = 0.1;
uniform vec3 sunColour = vec3(0.8, 0.9, 0.4);
uniform float moonRadius = 0.05;
uniform vec3 moonColour = vec3(0.7, 0.8, 0.9);
uniform float dayCycle;

void main() {
	float x = (eyeDirection.y >= 0 ? 1 : -1) * acos(dot(vec2(1, 0), eyeDirection.xy) / length(eyeDirection.xy)) / PI;
	float y = acos(dot(vec3(0, 0, -1), eyeDirection) / length(eyeDirection)) / PI;
	vec4 skyColor = texture(skyGradient, vec2(dayCycle, y));

	float sunSDF = length(eyeDirection - vec3(0, sin(dayCycle * PI), cos(dayCycle * PI)));
	float sunMask = smoothstep(0, 0.1, 1 - clamp(sunSDF / sunRadius, 0, 1));
	
	float moonSDF = length(eyeDirection - vec3(0, sin(-dayCycle * PI), cos(dayCycle * PI)));
	float moonMask = smoothstep(0, 0.1, 1 - clamp(moonSDF / moonRadius, 0, 1));

	fragColor = skyColor;
	fragColor = mix(fragColor, vec4(sunColour, 1), sunMask);
	fragColor = mix(fragColor, vec4(moonColour, 1), moonMask);
}