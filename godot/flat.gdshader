shader_type spatial;
// Düz (low-poly) gölgeleme: her yüzün normali ekran türevlerinden; yön kameraya göre düzeltilir.
uniform vec4 albedo : source_color = vec4(1.0);
void fragment() {
	vec3 n = normalize(cross(dFdx(VERTEX), dFdy(VERTEX)));
	if (dot(n, VIEW) < 0.0) { n = -n; }
	NORMAL = n;
	ALBEDO = albedo.rgb;
	ROUGHNESS = 0.92;
	SPECULAR = 0.2;
}
