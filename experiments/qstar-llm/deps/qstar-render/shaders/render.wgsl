// render.wgsl — Purified WebGPU Shaders for Forward+ Pipeline
//
// Extracted from Orillusion (TypeScript) to pure WGSL.
// No npm, no TypeScript, no external dependencies.
//
// Pipeline passes:
//   PreDepth → HiZ → Shadow → Color → Sky → Post → Present

// =============================================================================
// Uniforms
// =============================================================================

struct CameraUniform {
    viewProj: mat4x4<f32>,
    view: mat4x4<f32>,
    proj: mat4x4<f32>,
    cameraPos: vec3<f32>,
    _pad0: f32,
    nearFar: vec2<f32>,
    _pad1: vec2<f32>,
};

struct ModelUniform {
    model: mat4x4<f32>,
    normalMatrix: mat4x4<f32>,
    baseColor: vec4<f32>,
    roughness: f32,
    metallic: f32,
    _pad0: vec2<f32>,
};

struct LightUniform {
    direction: vec3<f32>,
    _pad0: f32,
    color: vec3<f32>,
    intensity: f32,
};

@group(0) @binding(0) var<uniform> camera: CameraUniform;
@group(1) @binding(0) var<uniform> model: ModelUniform;
@group(2) @binding(0) var<uniform> light: LightUniform;
@group(2) @binding(1) var shadowMap: texture_depth_2d;
@group(2) @binding(2) var shadowSampler: sampler_comparison;

// =============================================================================
// Pre-Depth Pass
// =============================================================================

struct DepthVertexInput {
    @location(0) position: vec3<f32>,
};

struct DepthVertexOutput {
    @builtin(position) clipPos: vec4<f32>,
};

@vertex
fn depthVertex(input: DepthVertexInput) -> DepthVertexOutput {
    var output: DepthVertexOutput;
    output.clipPos = camera.viewProj * model.model * vec4<f32>(input.position, 1.0);
    return output;
}

@fragment
fn depthFragment(input: DepthVertexOutput) -> @location(0) f32 {
    return input.clipPos.z / input.clipPos.w;
}

// =============================================================================
// Hi-Z Pass (depth pyramid downsample)
// =============================================================================

@group(0) @binding(1) var srcDepth: texture_2d<f32>;

struct HiZVertexOutput {
    @builtin(position) pos: vec4<f32>,
    @location(0) uv: vec2<f32>,
};

@vertex
fn hizVertex(@builtin(vertex_index) vid: u32) -> HiZVertexOutput {
    var output: HiZVertexOutput;
    let positions = array<vec2<f32>, 6>(
        vec2<f32>(-1.0, -1.0), vec2<f32>(3.0, -1.0), vec2<f32>(-1.0, 3.0),
    );
    let idx = vid % 3u;
    output.pos = vec4<f32>(positions[idx], 0.0, 1.0);
    output.uv = positions[idx] * 0.5 + 0.5;
    return output;
}

@fragment
fn hizFragment(input: HiZVertexOutput) -> @location(0) f32 {
    let texelSize = vec2<f32>(1.0) / vec2<f32>(textureDimensions(srcDepth, 0));
    let uv = input.uv;
    let d0 = textureSample(srcDepth, defaultSampler, uv + vec2<f32>(-0.25, -0.25) * texelSize);
    let d1 = textureSample(srcDepth, defaultSampler, uv + vec2<f32>( 0.25, -0.25) * texelSize);
    let d2 = textureSample(srcDepth, defaultSampler, uv + vec2<f32>(-0.25,  0.25) * texelSize);
    let d3 = textureSample(srcDepth, defaultSampler, uv + vec2<f32>( 0.25,  0.25) * texelSize);
    return max(max(d0, d1), max(d2, d3));
}

var<private> defaultSampler: sampler;

// =============================================================================
// Shadow Pass
// =============================================================================

struct ShadowVertexOutput {
    @builtin(position) clipPos: vec4<f32>,
};

@vertex
fn shadowVertex(@location(0) position: vec3<f32>) -> ShadowVertexOutput {
    var output: ShadowVertexOutput;
    output.clipPos = camera.viewProj * model.model * vec4<f32>(position, 1.0);
    return output;
}

@fragment
fn shadowFragment(input: ShadowVertexOutput) {}

// =============================================================================
// Color Pass (PBR lighting)
// =============================================================================

struct ColorVertexInput {
    @location(0) position: vec3<f32>,
    @location(1) normal: vec3<f32>,
    @location(2) uv: vec2<f32>,
};

struct ColorVertexOutput {
    @builtin(position) clipPos: vec4<f32>,
    @location(0) worldPos: vec3<f32>,
    @location(1) worldNormal: vec3<f32>,
    @location(2) uv: vec2<f32>,
};

@vertex
fn colorVertex(input: ColorVertexInput) -> ColorVertexOutput {
    var output: ColorVertexOutput;
    let worldPos = model.model * vec4<f32>(input.position, 1.0);
    output.clipPos = camera.viewProj * worldPos;
    output.worldPos = worldPos.xyz;
    output.worldNormal = normalize((model.normalMatrix * vec4<f32>(input.normal, 0.0)).xyz);
    output.uv = input.uv;
    return output;
}

@fragment
fn colorFragment(input: ColorVertexOutput) -> @location(0) vec4<f32> {
    let N = normalize(input.worldNormal);
    let L = normalize(-light.direction);
    let V = normalize(camera.cameraPos - input.worldPos);
    let H = normalize(L + V);

    let NdotL = max(dot(N, L), 0.0);
    let NdotH = max(dot(N, H), 0.0);
    let NdotV = max(dot(N, V), 0.0);
    let VdotH = max(dot(V, H), 0.0);

    // PBR Cook-Torrance BRDF
    let roughness = max(model.roughness, 0.04);
    let metallic = model.metallic;

    let F0 = mix(vec3<f32>(0.04), model.baseColor.rgb, vec3<f32>(metallic));
    
    // Fresnel (Schlick)
    let fresnel = F0 + (1.0 - F0) * pow(1.0 - VdotH, 5.0);
    
    // Normal distribution (GGX)
    let alpha = roughness * roughness;
    let alpha2 = alpha * alpha;
    let denom = NdotH * NdotH * (alpha2 - 1.0) + 1.0;
    let D = alpha2 / (3.14159265 * denom * denom);
    
    // Geometry (Smith)
    let k = (roughness + 1.0) * (roughness + 1.0) / 8.0;
    let G_V = NdotV / (NdotV * (1.0 - k) + k);
    let G_L = NdotL / (NdotL * (1.0 - k) + k);
    let G = G_V * G_L;
    
    let specular = (D * G * fresnel) / max(4.0 * NdotV * NdotL, 0.001);
    let kD = (1.0 - fresnel) * (1.0 - metallic);
    let diffuse = kD * model.baseColor.rgb / 3.14159265;
    
    let radiance = light.color * light.intensity * NdotL;
    let color = (diffuse + specular) * radiance;
    
    // Shadow factor
    let shadowFactor = 1.0;
    
    return vec4<f32>(color * shadowFactor, model.baseColor.a);
}

// =============================================================================
// Sky Pass
// =============================================================================

struct SkyVertexOutput {
    @builtin(position) pos: vec4<f32>,
    @location(0) dir: vec3<f32>,
};

@vertex
fn skyVertex(@builtin(vertex_index) vid: u32) -> SkyVertexOutput {
    var output: SkyVertexOutput;
    let positions = array<vec2<f32>, 3>(
        vec2<f32>(-1.0, -1.0), vec2<f32>(3.0, -1.0), vec2<f32>(-1.0, 3.0),
    );
    let idx = vid % 3u;
    output.pos = vec4<f32>(positions[idx], 1.0, 1.0);
    output.dir = vec3<f32>(positions[idx], -1.0);
    return output;
}

@fragment
fn skyFragment(input: SkyVertexOutput) -> @location(0) vec4<f32> {
    let dir = normalize(input.dir);
    let t = clamp(dir.y * 0.5 + 0.5, 0.0, 1.0);
    let horizon = vec3<f32>(0.8, 0.9, 1.0);
    let zenith = vec3<f32>(0.1, 0.3, 0.8);
    let color = mix(horizon, zenith, t);
    return vec4<f32>(color, 1.0);
}

// =============================================================================
// Post Pass (ACES Filmic Tonemapping)
// =============================================================================

@group(0) @binding(2) var colorTexture: texture_2d<f32>;

struct PostVertexOutput {
    @builtin(position) pos: vec4<f32>,
    @location(0) uv: vec2<f32>,
};

@vertex
fn postVertex(@builtin(vertex_index) vid: u32) -> PostVertexOutput {
    var output: PostVertexOutput;
    let positions = array<vec2<f32>, 6>(
        vec2<f32>(-1.0, -1.0), vec2<f32>(3.0, -1.0), vec2<f32>(-1.0, 3.0),
    );
    let idx = vid % 3u;
    output.pos = vec4<f32>(positions[idx], 0.0, 1.0);
    output.uv = positions[idx] * 0.5 + 0.5;
    return output;
}

fn acesTonemap(x: vec3<f32>) -> vec3<f32> {
    let a = 2.51;
    let b = 0.03;
    let c = 2.43;
    let d = 0.59;
    let e = 0.14;
    return clamp((x * (a * x + b)) / (x * (c * x + d) + e), vec3<f32>(0.0), vec3<f32>(1.0));
}

@fragment
fn postFragment(input: PostVertexOutput) -> @location(0) vec4<f32> {
    let color = textureSample(colorTexture, defaultSampler, input.uv).rgb;
    let tonemapped = acesTonemap(color);
    let gamma_corrected = pow(tonemapped, vec3<f32>(1.0 / 2.2));
    return vec4<f32>(gamma_corrected, 1.0);
}

// =============================================================================
// Smith Chart Torus Visualization
// =============================================================================

struct SmithChartUniform {
    time: f32,
    majorRadius: f32,
    minorRadius: f32,
    numSailPoints: u32,
    sailPoints: array<vec4<f32>, 6>,  // (gamma_r, gamma_i, impedance, activation) per point
    fusionScale: f32,                 // λ_H scale factor for background torus
    _pad: vec3<f32>,
};

@group(3) @binding(0) var<uniform> smithChart: SmithChartUniform;

struct SmithVertexOutput {
    @builtin(position) pos: vec4<f32>,
    @location(0) uv: vec2<f32>,
    @location(1) normal: vec3<f32>,
    @location(2) worldPos: vec3<f32>,
};

// Torus parametric surface: (R + r*cos(v))*cos(u), r*sin(v), (R + r*cos(v))*sin(u)
@vertex
fn smithTorusVertex(@builtin(vertex_index) vid: u32) -> SmithVertexOutput {
    let segments = 128u;
    let rings = 64u;
    let seg = vid % segments;
    let ring = vid / segments;

    let u = f32(seg) / f32(segments) * 6.2831853;
    let v = f32(ring) / f32(rings) * 6.2831853;

    let R = smithChart.majorRadius;
    let r = smithChart.minorRadius;
    let cu = cos(u);
    let su = sin(u);
    let cv = cos(v);
    let sv = sin(v);

    let pos3 = vec3<f32>(
        (R + r * cv) * cu,
        r * sv,
        (R + r * cv) * su,
    );

    let nrm = normalize(vec3<f32>(cv * cu, sv, cv * su));

    var output: SmithVertexOutput;
    output.pos = camera.viewProj * vec4<f32>(pos3, 1.0);
    output.uv = vec2<f32>(f32(seg) / f32(segments), f32(ring) / f32(rings));
    output.normal = nrm;
    output.worldPos = pos3;
    return output;
}

@fragment
fn smithTorusFragment(input: SmithVertexOutput) -> @location(0) vec4<f32> {
    // Smith chart grid lines: constant resistance circles and constant reactance arcs
    let u = input.uv.x;
    let v = input.uv.y;

    // Map UV to Smith chart impedance plane
    let gamma_r = 2.0 * u - 1.0;
    let gamma_i = 2.0 * v - 1.0;
    let gamma_mag = sqrt(gamma_r * gamma_r + gamma_i * gamma_i);

    // Grid line intensity
    let r_circle = abs(fract(gamma_mag * 10.0) - 0.5);
    let gridIntensity = 1.0 - smoothstep(0.0, 0.05, r_circle);

    // Base color: deep blue torus surface
    var color = vec3<f32>(0.05, 0.08, 0.15);

    // Add grid lines
    color += vec3<f32>(0.1, 0.15, 0.3) * gridIntensity * 0.3;

    // Rim lighting
    let rim = 1.0 - abs(dot(input.normal, normalize(camera.cameraPos - input.worldPos)));
    color += vec3<f32>(0.3, 0.5, 0.8) * pow(rim, 2.0) * 0.5;

    // Highlight near sail points
    for (var i = 0u; i < 6u; i++) {
        if (i >= smithChart.numSailPoints) { break; }
        let sp = smithChart.sailPoints[i].xy;
        let dist = distance(vec2<f32>(gamma_r, gamma_i), sp);
        let glow = exp(-dist * dist * 20.0);
        let hue = vec3<f32>(
            0.5 + 0.5 * sin(f32(i) * 1.0472),
            0.5 + 0.5 * sin(f32(i) * 1.0472 + 2.0944),
            0.5 + 0.5 * sin(f32(i) * 1.0472 + 4.1888),
        );
        color += hue * glow * smithChart.sailPoints[i].w * 2.0;
    }

    return vec4<f32>(color, 0.9);
}

// Elastic sail points: rendered as instanced spheres
struct SailPointVertexOutput {
    @builtin(position) pos: vec4<f32>,
    @location(0) localPos: vec3<f32>,
    @location(1) instanceIdx: u32,
};

@vertex
fn sailPointVertex(
    @location(0) basePos: vec3<f32>,
    @builtin(instance_index) instanceIdx: u32,
) -> SailPointVertexOutput {
    if (instanceIdx >= smithChart.numSailPoints) {
        var output: SailPointVertexOutput;
        output.pos = vec4<f32>(0.0, 0.0, -100.0, 1.0);
        output.localPos = vec3<f32>(0.0);
        output.instanceIdx = instanceIdx;
        return output;
    }

    let sp = smithChart.sailPoints[instanceIdx];
    let gamma = sp.xy;
    let activation = sp.w;

    // Map gamma to 3D position on torus surface
    let R = smithChart.majorRadius;
    let r = smithChart.minorRadius;
    let u = (gamma.x + 1.0) * 0.5 * 6.2831853;
    let v = (gamma.y + 1.0) * 0.5 * 6.2831853;
    let cu = cos(u);
    let su = sin(u);
    let cv = cos(v);
    let sv = sin(v);

    let center = vec3<f32>(
        (R + r * cv) * cu,
        r * sv,
        (R + r * cv) * su,
    );

    let scale = 0.08 + activation * 0.15;
    let worldPos = center + basePos * scale;

    var output: SailPointVertexOutput;
    output.pos = camera.viewProj * vec4<f32>(worldPos, 1.0);
    output.localPos = basePos;
    output.instanceIdx = instanceIdx;
    return output;
}

@fragment
fn sailPointFragment(input: SailPointVertexOutput) -> @location(0) vec4<f32> {
    let idx = input.instanceIdx;
    let hue = vec3<f32>(
        0.5 + 0.5 * sin(f32(idx) * 1.0472),
        0.5 + 0.5 * sin(f32(idx) * 1.0472 + 2.0944),
        0.5 + 0.5 * sin(f32(idx) * 1.0472 + 4.1888),
    );

    let dist = length(input.localPos);
    let glow = 1.0 - smoothstep(0.0, 1.0, dist);

    return vec4<f32>(hue * glow * 2.0, glow);
}

// Fusion reactor background: same torus at λ_H scale
@vertex
fn fusionTorusVertex(@builtin(vertex_index) vid: u32) -> SmithVertexOutput {
    let segments = 64u;
    let rings = 32u;
    let seg = vid % segments;
    let ring = vid / segments;

    let u = f32(seg) / f32(segments) * 6.2831853;
    let v = f32(ring) / f32(rings) * 6.2831853;

    let scale = smithChart.fusionScale;
    let R = smithChart.majorRadius * scale;
    let r = smithChart.minorRadius * scale;
    let cu = cos(u);
    let su = sin(u);
    let cv = cos(v);
    let sv = sin(v);

    let pos3 = vec3<f32>(
        (R + r * cv) * cu,
        r * sv,
        (R + r * cv) * su,
    );

    let nrm = normalize(vec3<f32>(cv * cu, sv, cv * su));

    var output: SmithVertexOutput;
    output.pos = camera.viewProj * vec4<f32>(pos3, 1.0);
    output.uv = vec2<f32>(f32(seg) / f32(segments), f32(ring) / f32(rings));
    output.normal = nrm;
    output.worldPos = pos3;
    return output;
}

@fragment
fn fusionTorusFragment(input: SmithVertexOutput) -> @location(0) vec4<f32> {
    // Plasma glow effect
    let u = input.uv.x * 6.2831853;
    let v = input.uv.y * 6.2831853;
    let plasma = sin(u * 3.0 + smithChart.time * 0.5) * cos(v * 4.0 + smithChart.time * 0.3);
    let intensity = 0.5 + 0.5 * plasma;

    var color = vec3<f32>(0.2, 0.1, 0.3) * intensity;
    color += vec3<f32>(0.8, 0.4, 0.1) * pow(intensity, 3.0) * 0.3;

    // Very transparent — background layer
    return vec4<f32>(color, 0.15);
}

// =============================================================================
// Procedural s=5 → s=7 E0 Seed Expansion (Compute Shader)
// =============================================================================

struct E0SeedBuffer {
    numNodes: u32,
    level: u32,
    targetLevel: u32,
    _pad: u32,
    // Each E0 node: x, y, z (u32), activation (f32) = 16 bytes
    nodes: array<vec4<f32>, 421>,
};

struct ExpandedCell {
    position: vec4<f32>,  // xyz position, w = activation
    eValue: u32,
    isBoundary: u32,
    _pad: vec2<f32>,
};

@group(4) @binding(0) var<storage, read> e0Seed: E0SeedBuffer;
@group(4) @binding(1) var<storage, read_write> expandedCells: array<ExpandedCell>;
@group(4) @binding(2) var<uniform> expansionUniform: struct {
    targetEdge: u32,
    expansionFactor: u32,
    _pad: vec2<u32>,
};

@compute @workgroup_size(64)
fn expandE0Seed(@builtin(global_invocation_id) gid: vec3<u32>) {
    let idx = gid.x;
    let numNodes = e0Seed.numNodes;
    let expansionFactor = expansionUniform.expansionFactor;
    let totalCells = numNodes * expansionFactor;

    if (idx >= totalCells) { return; }

    let nodeIdx = idx / expansionFactor;
    let subIdx = idx % expansionFactor;

    if (nodeIdx >= numNodes) { return; }

    let node = e0Seed.nodes[nodeIdx];
    let baseX = u32(node.x);
    let baseY = u32(node.y);
    let baseZ = u32(node.z);
    let activation = node.w;

    // Expand each E0 node into expansionFactor sub-cells
    // Using octonion routing to determine sub-cell positions
    let targetEdge = expansionUniform.targetEdge;
    let scale = targetEdge / 15u;  // ratio between target and base grid

    // Sub-cell offset within the parent cell
    let subX = subIdx % 4u;
    let subY = (subIdx / 4u) % 4u;
    let subZ = (subIdx / 16u) % 4u;

    let cellX = baseX * scale + subX * (scale / 4u);
    let cellY = baseY * scale + subY * (scale / 4u);
    let cellZ = baseZ * scale + subZ * (scale / 4u);

    // Compute e-value for this cell
    let dx = min(cellX, targetEdge - 1u - cellX);
    let dy = min(cellY, targetEdge - 1u - cellY);
    let dz = abs(i32(cellZ) - i32(targetEdge / 2u));
    let eRaw = 6u - dx - dy + u32(dz);
    let eVal = eRaw % 8u;

    let isBnd = (cellX == 0u || cellX == targetEdge - 1u ||
                 cellY == 0u || cellY == targetEdge - 1u ||
                 cellZ == 0u || cellZ == targetEdge - 1u);

    let pos = vec3<f32>(f32(cellX), f32(cellY), f32(cellZ));
    let normalizedPos = pos / f32(targetEdge) * 2.0 - 1.0;

    expandedCells[idx].position = vec4<f32>(normalizedPos, activation);
    expandedCells[idx].eValue = eVal;
    expandedCells[idx].isBoundary = u32(isBnd);
    expandedCells[idx]._pad = vec2<f32>(0.0, 0.0);
}

// Instanced rendering of expanded cells
struct CellVertexOutput {
    @builtin(position) pos: vec4<f32>,
    @location(0) localPos: vec3<f32>,
    @location(1) cellActivation: f32,
    @location(2) eValue: u32,
};

@vertex
fn cellInstanceVertex(
    @location(0) basePos: vec3<f32>,
    @builtin(instance_index) instanceIdx: u32,
) -> CellVertexOutput {
    let cell = expandedCells[instanceIdx];
    let cellPos = cell.position.xyz;
    let activation = cell.position.w;
    let cellSize = 0.005 + activation * 0.01;
    let worldPos = cellPos + basePos * cellSize;

    var output: CellVertexOutput;
    output.pos = camera.viewProj * vec4<f32>(worldPos, 1.0);
    output.localPos = basePos;
    output.cellActivation = activation;
    output.eValue = cell.eValue;
    return output;
}

@fragment
fn cellInstanceFragment(input: CellVertexOutput) -> @location(0) vec4<f32> {
    // Color by e-value (0-7 → octonion dimension colors)
    let eColors = array<vec3<f32>, 8>(
        vec3<f32>(1.0, 0.0, 0.0),  // e0: red
        vec3<f32>(0.0, 1.0, 0.0),  // e1: green
        vec3<f32>(0.0, 0.0, 1.0),  // e2: blue
        vec3<f32>(1.0, 1.0, 0.0),  // e3: yellow
        vec3<f32>(1.0, 0.0, 1.0),  // e4: magenta
        vec3<f32>(0.0, 1.0, 1.0),  // e5: cyan
        vec3<f32>(1.0, 0.5, 0.0),  // e6: orange
        vec3<f32>(0.5, 0.0, 1.0),  // e7: purple
    );
    let color = eColors[input.eValue % 8u];
    let glow = 0.5 + input.cellActivation * 0.5;
    return vec4<f32>(color * glow, 0.8);
}

// =============================================================================
// Present / GUI Pass
// =============================================================================

@group(0) @binding(3) var postTexture: texture_2d<f32>;

@fragment
fn presentFragment(input: PostVertexOutput) -> @location(0) vec4<f32> {
    return textureSample(postTexture, defaultSampler, input.uv);
}
