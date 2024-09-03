#version 330

layout (location=0) in vec3 vertexPos;

out vec3 eyeDirection;

uniform mat4 projectionMatrix;
uniform mat4 viewMatrix;

void main() {
	mat4 inverseProjection = inverse(projectionMatrix);
    mat4 inverseModelview = inverse(viewMatrix);
    eyeDirection = (inverseModelview * inverseProjection * vec4(vertexPos, 1)).xyz;

	gl_Position = vec4(vertexPos, 1);
	gl_Position.z = gl_Position.w - 0.00001; //fix to far plane
}