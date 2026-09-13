const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // === Vulkan Build Option ===
    const vulkan_enabled = b.option(bool, "vulkan", "Enable Vulkan shader compilation (requires glslc)") orelse false;

    // === P2P Build Option ===
    // Auto-detect: enable when the vendored qstar-net and qstar-vfs repos are present.
    // Can be forced on/off with -Dp2p=true / -Dp2p=false.
    const p2p_auto = blk: {
        const net_file = std.fs.cwd().openFile("deps/qstar-net/src/bootstrap.zig", .{}) catch break :blk false;
        net_file.close();
        const vfs_file = std.fs.cwd().openFile("deps/qstar-vfs/src/vfs_distributed.zig", .{}) catch break :blk false;
        vfs_file.close();
        break :blk true;
    };
    const p2p_enabled = b.option(bool, "p2p", "Enable P2P mesh (requires qstar-net + qstar-vfs repos in deps/)") orelse p2p_auto;

    // === Module Definitions ===

    const fixed_point_mod = b.addModule("fixed_point", .{
        .root_source_file = b.path("src/fixed_point.zig"),
        .target = target,
        .optimize = optimize,
    });

    const q128_mod = b.addModule("q128", .{
        .root_source_file = b.path("src/q128.zig"),
        .target = target,
        .optimize = optimize,
    });
    const hardware_detect_mod = b.addModule("hardware_detect", .{
        .root_source_file = b.path("src/hardware_detect.zig"),
        .target = target,
        .optimize = optimize,
    });

    const fixed_point32_mod = b.addModule("fixed_point32", .{
        .root_source_file = b.path("src/fixed_point32.zig"),
        .target = target,
        .optimize = optimize,
    });

    const fp_bridge_mod = b.addModule("fp_bridge", .{
        .root_source_file = b.path("src/fp_bridge.zig"),
        .target = target,
        .optimize = optimize,
    });
    fp_bridge_mod.addImport("fixed_point", fixed_point_mod);
    fp_bridge_mod.addImport("fixed_point32", fixed_point32_mod);

    const precision_scaler_mod = b.addModule("precision_scaler", .{
        .root_source_file = b.path("src/precision_scaler.zig"),
        .target = target,
        .optimize = optimize,
    });
    precision_scaler_mod.addImport("fixed_point", fixed_point_mod);
    precision_scaler_mod.addImport("fixed_point32", fixed_point32_mod);
    precision_scaler_mod.addImport("fp_bridge", fp_bridge_mod);
    precision_scaler_mod.addImport("hardware_detect", hardware_detect_mod);

    const lattice_mod = b.addModule("lattice", .{
        .root_source_file = b.path("src/lattice.zig"),
        .target = target,
        .optimize = optimize,
    });

    const octonion_math_mod = b.addModule("octonion_math", .{
        .root_source_file = b.path("src/octonion_math.zig"),
        .target = target,
        .optimize = optimize,
    });
    octonion_math_mod.addImport("fixed_point", fixed_point_mod);

    const hw_bridge_mod = b.addModule("hw_bridge", .{
        .root_source_file = b.path("src/hw_bridge.zig"),
        .target = target,
        .optimize = optimize,
    });
    hw_bridge_mod.addImport("fixed_point", fixed_point_mod);
    hw_bridge_mod.addImport("octonion_math", octonion_math_mod);

    const sentience_scorer_mod = b.addModule("sentience_scorer", .{
        .root_source_file = b.path("src/sentience_scorer.zig"),
        .target = target,
        .optimize = optimize,
    });

    const sentience_experiment_mod = b.addModule("sentience_experiment", .{
        .root_source_file = b.path("src/sentience_experiment.zig"),
        .target = target,
        .optimize = optimize,
    });
    sentience_experiment_mod.addImport("sentience_scorer", sentience_scorer_mod);

    const holo_codec_mod = b.addModule("holo_codec", .{
        .root_source_file = b.path("src/holo_codec.zig"),
        .target = target,
        .optimize = optimize,
    });

    const e8_roots_mod = b.addModule("e8_roots", .{
        .root_source_file = b.path("src/e8_roots.zig"),
        .target = target,
        .optimize = optimize,
    });

    const jordan_algebra_mod = b.addModule("jordan_algebra", .{
        .root_source_file = b.path("src/jordan_algebra.zig"),
        .target = target,
        .optimize = optimize,
    });
    jordan_algebra_mod.addImport("octonion_math", octonion_math_mod);

    const so10_mod = b.addModule("so10", .{
        .root_source_file = b.path("src/so10.zig"),
        .target = target,
        .optimize = optimize,
    });

    const bpe_mod = b.addModule("bpe_tokenizer", .{
        .root_source_file = b.path("src/bpe_tokenizer.zig"),
        .target = target,
        .optimize = optimize,
    });

    const sampling_mod = b.addModule("sampling", .{
        .root_source_file = b.path("src/sampling.zig"),
        .target = target,
        .optimize = optimize,
    });
    sampling_mod.addImport("q128", q128_mod);

    const memory_mod = b.addModule("memory", .{
        .root_source_file = b.path("src/memory.zig"),
        .target = target,
        .optimize = optimize,
    });

    const perception_mod = b.addModule("perception", .{
        .root_source_file = b.path("src/perception.zig"),
        .target = target,
        .optimize = optimize,
    });
    perception_mod.addImport("fixed_point", fixed_point_mod);

    const kg_mod = b.addModule("knowledge_graph", .{
        .root_source_file = b.path("src/knowledge_graph.zig"),
        .target = target,
        .optimize = optimize,
    });
    kg_mod.addImport("fixed_point", fixed_point_mod);
    kg_mod.addImport("lattice", lattice_mod);

    const state_store_mod = b.addModule("state_store", .{
        .root_source_file = b.path("src/state_store.zig"),
        .target = target,
        .optimize = optimize,
    });

    const face_sync_mod = b.addModule("face_sync", .{
        .root_source_file = b.path("src/face_sync.zig"),
        .target = target,
        .optimize = optimize,
    });
    face_sync_mod.addImport("fixed_point", fixed_point_mod);

    const dynamic_routes_mod = b.addModule("dynamic_routes", .{
        .root_source_file = b.path("src/dynamic_routes.zig"),
        .target = target,
        .optimize = optimize,
    });

    const metacognition_engine_mod = b.addModule("metacognition_engine", .{
        .root_source_file = b.path("src/metacognition_engine.zig"),
        .target = target,
        .optimize = optimize,
    });
    metacognition_engine_mod.addImport("dynamic_routes", dynamic_routes_mod);
    metacognition_engine_mod.addImport("hw_bridge", hw_bridge_mod);
    metacognition_engine_mod.addImport("q128", q128_mod);

    const trivium_mod = b.addModule("trivium", .{
        .root_source_file = b.path("src/trivium.zig"),
        .target = target,
        .optimize = optimize,
    });

    const quadrivium_mod = b.addModule("quadrivium", .{
        .root_source_file = b.path("src/quadrivium.zig"),
        .target = target,
        .optimize = optimize,
    });
    quadrivium_mod.addImport("fixed_point", fixed_point_mod);

    const corpus_learner_mod = b.addModule("corpus_learner", .{
        .root_source_file = b.path("src/corpus_learner.zig"),
        .target = target,
        .optimize = optimize,
    });
    corpus_learner_mod.addImport("trivium", trivium_mod);
    corpus_learner_mod.addImport("quadrivium", quadrivium_mod);
    corpus_learner_mod.addImport("dynamic_routes", dynamic_routes_mod);

    const cognitive_cloud_mod = b.addModule("cognitive_cloud", .{
        .root_source_file = b.path("src/cognitive_cloud.zig"),
        .target = target,
        .optimize = optimize,
    });
    cognitive_cloud_mod.addImport("fixed_point", fixed_point_mod);

    const holographic_memory_mod = b.addModule("holographic_memory", .{
        .root_source_file = b.path("src/holographic_memory.zig"),
        .target = target,
        .optimize = optimize,
    });
    holographic_memory_mod.addImport("fixed_point", fixed_point_mod);
    holographic_memory_mod.addImport("cognitive_cloud", cognitive_cloud_mod);

    const voice_codec_mod = b.addModule("voice_codec", .{
        .root_source_file = b.path("src/voice_codec.zig"),
        .target = target,
        .optimize = optimize,
    });
    voice_codec_mod.addImport("fixed_point", fixed_point_mod);

    const agent_mod = b.addModule("agent", .{
        .root_source_file = b.path("src/agent.zig"),
        .target = target,
        .optimize = optimize,
    });
    agent_mod.addImport("bpe_tokenizer", bpe_mod);
    agent_mod.addImport("sampling", sampling_mod);
    agent_mod.addImport("state_store", state_store_mod);
    agent_mod.addImport("face_sync", face_sync_mod);
    agent_mod.addImport("fixed_point", fixed_point_mod);
    agent_mod.addImport("q128", q128_mod);
    agent_mod.addImport("knowledge_graph", kg_mod);
    agent_mod.addImport("memory", memory_mod);
    agent_mod.addImport("perception", perception_mod);
    agent_mod.addImport("metacognition_engine", metacognition_engine_mod);
    agent_mod.addImport("dynamic_routes", dynamic_routes_mod);
    agent_mod.addImport("trivium", trivium_mod);
    agent_mod.addImport("quadrivium", quadrivium_mod);
    agent_mod.addImport("corpus_learner", corpus_learner_mod);
    agent_mod.addImport("cognitive_cloud", cognitive_cloud_mod);
    agent_mod.addImport("voice_codec", voice_codec_mod);
    agent_mod.addImport("lattice", lattice_mod);
    agent_mod.addImport("octonion_math", octonion_math_mod);
    agent_mod.addImport("hw_bridge", hw_bridge_mod);
    agent_mod.addImport("sentience_scorer", sentience_scorer_mod);
    agent_mod.addImport("sentience_experiment", sentience_experiment_mod);
    agent_mod.addImport("holo_codec", holo_codec_mod);
    agent_mod.addImport("e8_roots", e8_roots_mod);
    agent_mod.addImport("jordan_algebra", jordan_algebra_mod);
    agent_mod.addImport("so10", so10_mod);

    const corpus_seed_mod = b.addModule("corpus_seed", .{
        .root_source_file = b.path("src/corpus_seed.zig"),
        .target = target,
        .optimize = optimize,
    });
    agent_mod.addImport("corpus_seed", corpus_seed_mod);

    const vulkan_compute_mod = b.addModule("vulkan_compute", .{
        .root_source_file = b.path("src/vulkan_compute.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    agent_mod.addImport("vulkan_compute", vulkan_compute_mod);

    const c_ffi_mod = b.addModule("c_ffi", .{
        .root_source_file = b.path("src/c_ffi.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    const image_mod = b.addModule("image", .{
        .root_source_file = b.path("src/vision/image.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    image_mod.addImport("c_ffi", c_ffi_mod);

    const face_detect_mod = b.addModule("face_detect", .{
        .root_source_file = b.path("src/vision/face_detect.zig"),
        .target = target,
        .optimize = optimize,
    });
    face_detect_mod.addImport("image", image_mod);

    const face_recognize_mod = b.addModule("face_recognize", .{
        .root_source_file = b.path("src/vision/face_recognize.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    face_recognize_mod.addImport("image", image_mod);
    face_recognize_mod.addImport("c_ffi", c_ffi_mod);

    const face_landmark_mod = b.addModule("face_landmark", .{
        .root_source_file = b.path("src/vision/face_landmark.zig"),
        .target = target,
        .optimize = optimize,
    });
    face_landmark_mod.addImport("face_detect", face_detect_mod);

    const face_track_mod = b.addModule("face_track", .{
        .root_source_file = b.path("src/vision/face_track.zig"),
        .target = target,
        .optimize = optimize,
    });
    face_track_mod.addImport("face_detect", face_detect_mod);

    const gaze_headpose_mod = b.addModule("gaze_headpose", .{
        .root_source_file = b.path("src/vision/gaze_headpose.zig"),
        .target = target,
        .optimize = optimize,
    });
    gaze_headpose_mod.addImport("face_detect", face_detect_mod);
    gaze_headpose_mod.addImport("face_landmark", face_landmark_mod);

    const face_attributes_mod = b.addModule("face_attributes", .{
        .root_source_file = b.path("src/vision/face_attributes.zig"),
        .target = target,
        .optimize = optimize,
    });

    const face_parsing_mod = b.addModule("face_parsing", .{
        .root_source_file = b.path("src/vision/face_parsing.zig"),
        .target = target,
        .optimize = optimize,
    });
    face_parsing_mod.addImport("image", image_mod);

    const face_quality_mod = b.addModule("face_quality", .{
        .root_source_file = b.path("src/vision/face_quality.zig"),
        .target = target,
        .optimize = optimize,
    });
    face_quality_mod.addImport("image", image_mod);
    face_quality_mod.addImport("face_detect", face_detect_mod);

    const anti_spoofing_mod = b.addModule("anti_spoofing", .{
        .root_source_file = b.path("src/vision/anti_spoofing.zig"),
        .target = target,
        .optimize = optimize,
    });
    anti_spoofing_mod.addImport("image", image_mod);
    anti_spoofing_mod.addImport("face_detect", face_detect_mod);

    const face_analyzer_mod = b.addModule("face_analyzer", .{
        .root_source_file = b.path("src/vision/face_analyzer.zig"),
        .target = target,
        .optimize = optimize,
    });
    face_analyzer_mod.addImport("image", image_mod);
    face_analyzer_mod.addImport("face_detect", face_detect_mod);
    face_analyzer_mod.addImport("face_recognize", face_recognize_mod);
    face_analyzer_mod.addImport("face_landmark", face_landmark_mod);
    face_analyzer_mod.addImport("face_track", face_track_mod);
    face_analyzer_mod.addImport("gaze_headpose", gaze_headpose_mod);
    face_analyzer_mod.addImport("face_attributes", face_attributes_mod);
    face_analyzer_mod.addImport("face_parsing", face_parsing_mod);
    face_analyzer_mod.addImport("face_quality", face_quality_mod);
    face_analyzer_mod.addImport("anti_spoofing", anti_spoofing_mod);

    // --- Geoview modules ---

    const geo_math_mod = b.addModule("geo_math", .{
        .root_source_file = b.path("src/geoview/geo_math.zig"),
        .target = target,
        .optimize = optimize,
    });

    const globe_render_mod = b.addModule("globe_render", .{
        .root_source_file = b.path("src/geoview/globe_render.zig"),
        .target = target,
        .optimize = optimize,
    });

    const camera_mod = b.addModule("camera", .{
        .root_source_file = b.path("src/geoview/camera.zig"),
        .target = target,
        .optimize = optimize,
    });
    camera_mod.addImport("geo_math", geo_math_mod);
    camera_mod.addImport("globe_render", globe_render_mod);

    // --- Geoview feed modules ---

    const live_feeds_mod = b.addModule("live_feeds", .{
        .root_source_file = b.path("src/geoview/live_feeds.zig"),
        .target = target,
        .optimize = optimize,
    });

    const feed_flights_mod = b.addModule("feed_flights", .{
        .root_source_file = b.path("src/geoview/feed_flights.zig"),
        .target = target,
        .optimize = optimize,
    });
    feed_flights_mod.addImport("geo_math", geo_math_mod);

    const feed_vessels_mod = b.addModule("feed_vessels", .{
        .root_source_file = b.path("src/geoview/feed_vessels.zig"),
        .target = target,
        .optimize = optimize,
    });
    feed_vessels_mod.addImport("geo_math", geo_math_mod);

    const feed_satellites_mod = b.addModule("feed_satellites", .{
        .root_source_file = b.path("src/geoview/feed_satellites.zig"),
        .target = target,
        .optimize = optimize,
    });
    feed_satellites_mod.addImport("geo_math", geo_math_mod);

    const feed_earthquakes_mod = b.addModule("feed_earthquakes", .{
        .root_source_file = b.path("src/geoview/feed_earthquakes.zig"),
        .target = target,
        .optimize = optimize,
    });

    const feed_traffic_mod = b.addModule("feed_traffic", .{
        .root_source_file = b.path("src/geoview/feed_traffic.zig"),
        .target = target,
        .optimize = optimize,
    });
    _ = feed_traffic_mod; // referenced in future phases

    const feed_cctv_mod = b.addModule("feed_cctv", .{
        .root_source_file = b.path("src/geoview/feed_cctv.zig"),
        .target = target,
        .optimize = optimize,
    });
    feed_cctv_mod.addImport("geo_math", geo_math_mod);

    // --- Geoview overlay/HUD modules ---

    const hud_mod = b.addModule("hud", .{
        .root_source_file = b.path("src/geoview/hud.zig"),
        .target = target,
        .optimize = optimize,
    });

    const detection_overlay_mod = b.addModule("detection_overlay", .{
        .root_source_file = b.path("src/geoview/detection_overlay.zig"),
        .target = target,
        .optimize = optimize,
    });

    const annotation_mod = b.addModule("annotation", .{
        .root_source_file = b.path("src/geoview/annotation.zig"),
        .target = target,
        .optimize = optimize,
    });

    const scene_director_mod = b.addModule("scene_director", .{
        .root_source_file = b.path("src/geoview/scene_director.zig"),
        .target = target,
        .optimize = optimize,
    });

    const styles_mod = b.addModule("styles", .{
        .root_source_file = b.path("src/geoview/styles.zig"),
        .target = target,
        .optimize = optimize,
    });
    styles_mod.addImport("hud", hud_mod);

    _ = detection_overlay_mod; // referenced in future phases

    const voice_command_mod = b.addModule("voice_command", .{
        .root_source_file = b.path("src/geoview/voice_command.zig"),
        .target = target,
        .optimize = optimize,
    });

    // --- New modules ---

    const ollama_mod = b.addModule("ollama_client", .{
        .root_source_file = b.path("src/ollama_client.zig"),
        .target = target,
        .optimize = optimize,
    });

    const prompt_gen_test_mod = b.addModule("prompt_generator", .{
        .root_source_file = b.path("src/prompt_generator.zig"),
        .target = target,
        .optimize = optimize,
    });
    prompt_gen_test_mod.addImport("ollama_client", ollama_mod);

    const env_loader_mod = b.addModule("env_loader", .{
        .root_source_file = b.path("src/env_loader.zig"),
        .target = target,
        .optimize = optimize,
    });

    const dynamic_dns_mod = b.addModule("dynamic_dns", .{
        .root_source_file = b.path("src/dynamic_dns.zig"),
        .target = target,
        .optimize = optimize,
    });

    const openai_mod = b.addModule("openai_client", .{
        .root_source_file = b.path("src/openai_client.zig"),
        .target = target,
        .optimize = optimize,
    });

    const compress_mod = b.addModule("compress", .{
        .root_source_file = b.path("src/compress.zig"),
        .target = target,
        .optimize = optimize,
    });

    const llm_provider_mod = b.addModule("llm_provider", .{
        .root_source_file = b.path("src/llm_provider.zig"),
        .target = target,
        .optimize = optimize,
    });
    llm_provider_mod.addImport("ollama_client", ollama_mod);
    llm_provider_mod.addImport("openai_client", openai_mod);
    llm_provider_mod.addImport("env_loader", env_loader_mod);

    const corpus_store_mod = b.addModule("corpus_store", .{
        .root_source_file = b.path("src/corpus_store.zig"),
        .target = target,
        .optimize = optimize,
    });
    corpus_store_mod.addImport("compress", compress_mod);

    const doc_loader_mod = b.addModule("doc_loader", .{
        .root_source_file = b.path("src/doc_loader.zig"),
        .target = target,
        .optimize = optimize,
    });

    const memory_pool_mod = b.addModule("memory_pool", .{
        .root_source_file = b.path("src/memory_pool.zig"),
        .target = target,
        .optimize = optimize,
    });

    const config_mod = b.addModule("config", .{
        .root_source_file = b.path("src/config.zig"),
        .target = target,
        .optimize = optimize,
    });
    config_mod.addImport("fixed_point", fixed_point_mod);

    const external_db_mod = b.addModule("external_db", .{
        .root_source_file = b.path("src/external_db.zig"),
        .target = target,
        .optimize = optimize,
    });
    external_db_mod.addImport("knowledge_graph", kg_mod);

    const continual_learner_mod = b.addModule("continual_learner", .{
        .root_source_file = b.path("src/continual_learner.zig"),
        .target = target,
        .optimize = optimize,
    });
    continual_learner_mod.addImport("knowledge_graph", kg_mod);
    continual_learner_mod.addImport("dynamic_routes", dynamic_routes_mod);
    continual_learner_mod.addImport("metacognition_engine", metacognition_engine_mod);

    const training_mod = b.addModule("training", .{
        .root_source_file = b.path("src/training.zig"),
        .target = target,
        .optimize = optimize,
    });
    training_mod.addImport("agent", agent_mod);
    training_mod.addImport("ollama_client", ollama_mod);
    training_mod.addImport("openai_client", openai_mod);
    training_mod.addImport("doc_loader", doc_loader_mod);
    training_mod.addImport("corpus_store", corpus_store_mod);
    training_mod.addImport("fixed_point", fixed_point_mod);
    training_mod.addImport("prompt_generator", prompt_gen_test_mod);

    const turing_test_mod = b.addModule("turing_test", .{
        .root_source_file = b.path("src/turing_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    turing_test_mod.addImport("agent", agent_mod);
    turing_test_mod.addImport("ollama_client", ollama_mod);
    turing_test_mod.addImport("fixed_point", fixed_point_mod);
    turing_test_mod.addImport("q128", q128_mod);

    const tools_mod = b.addModule("tools", .{
        .root_source_file = b.path("src/tools.zig"),
        .target = target,
        .optimize = optimize,
    });
    tools_mod.addImport("fixed_point", fixed_point_mod);
    tools_mod.addImport("knowledge_graph", kg_mod);
    tools_mod.addImport("external_db", external_db_mod);
    tools_mod.addImport("geo_math", geo_math_mod);

    agent_mod.addImport("tools", tools_mod);

    const server_mod = b.addModule("server", .{
        .root_source_file = b.path("src/server.zig"),
        .target = target,
        .optimize = optimize,
    });
    server_mod.addImport("agent", agent_mod);
    server_mod.addImport("fixed_point", fixed_point_mod);
    server_mod.addImport("tools", tools_mod);
    server_mod.addImport("bpe_tokenizer", bpe_mod);
    server_mod.addImport("knowledge_graph", kg_mod);
    server_mod.addImport("external_db", external_db_mod);
    server_mod.addImport("turing_test", turing_test_mod);

    // --- Holographic module (needed by s0_projection, s7_compression) ---

    const holographic_mod = b.addModule("holographic", .{
        .root_source_file = b.path("src/holographic.zig"),
        .target = target,
        .optimize = optimize,
    });
    holographic_mod.addImport("fixed_point", fixed_point_mod);

    // --- Prototype modules removed (prototype/ directory not present) ---

    // === Vulkan Shader Compilation Step ===

    const shaders_step = b.step("shaders", "Compile GLSL compute shaders to SPIR-V (requires glslc)");
    if (vulkan_enabled) {
        const shaders = [_][]const u8{
            "shaders/lattice_step.comp",
            "shaders/logits_proj.comp",
            "shaders/samc_relax.comp",
        };
        for (shaders) |shader_src| {
            const dot_pos = std.mem.indexOfScalar(u8, shader_src, '.') orelse 0;
            const base_name = shader_src[std.mem.lastIndexOfScalar(u8, shader_src, '/').? + 1 .. dot_pos];
            const spv_path = std.mem.concat(b.allocator, u8, &.{ "src/shaders/", base_name, ".spv" }) catch continue;
            const compile_cmd = b.addSystemCommand(&.{ "glslc", "-fshader-stage=comp", "-o", spv_path, shader_src });
            shaders_step.dependOn(&compile_cmd.step);
        }
    }

    // === Test Step ===

    const test_step = b.step("test", "Run all unit tests");

    // === Master Node Modules (autoupdate server + P2P mirror) ===
    const master_server_mod = b.addModule("master_server", .{
        .root_source_file = b.path("src/master_server.zig"),
        .target = target,
        .optimize = optimize,
    });
    master_server_mod.addImport("dynamic_dns", dynamic_dns_mod);
    const p2p_update_mod = b.addModule("p2p_update", .{
        .root_source_file = b.path("src/p2p_update.zig"),
        .target = target,
        .optimize = optimize,
    });
    if (p2p_enabled) {
        const net_bootstrap_mod = b.addModule("bootstrap", .{
            .root_source_file = b.path("deps/qstar-net/src/bootstrap.zig"),
            .target = target,
            .optimize = optimize,
        });
        const vfs_distributed_mod = b.addModule("vfs_distributed", .{
            .root_source_file = b.path("deps/qstar-vfs/src/vfs_distributed.zig"),
            .target = target,
            .optimize = optimize,
        });
        p2p_update_mod.addImport("bootstrap", net_bootstrap_mod);
        p2p_update_mod.addImport("vfs_distributed", vfs_distributed_mod);

        // p2p_update test (requires external repos in scope)
        const p2p_test = b.addTest(.{
            .root_source_file = b.path("src/p2p_update.zig"),
            .target = target,
            .optimize = optimize,
        });
        p2p_test.root_module.addImport("bootstrap", net_bootstrap_mod);
        p2p_test.root_module.addImport("vfs_distributed", vfs_distributed_mod);
        test_step.dependOn(&b.addRunArtifact(p2p_test).step);
    }

    // === Full Deps Build Option ===
    // Auto-detect: enable when all 8 qstar-* repos are present in deps/.
    // Can be forced on/off with -Dfull-deps=true / -Dfull-deps=false.
    const full_deps_auto = blk: {
        const mesh_file = std.fs.cwd().openFile("deps/qstar-mesh/src/mesh.zig", .{}) catch break :blk false;
        mesh_file.close();
        const transport_file = std.fs.cwd().openFile("deps/qstar-transport/src/maypole_bridge.zig", .{}) catch break :blk false;
        transport_file.close();
        const compress_file = std.fs.cwd().openFile("deps/qstar-compress/src/compress.zig", .{}) catch break :blk false;
        compress_file.close();
        const collapse_file = std.fs.cwd().openFile("deps/qstar-collapse/src/collapse.zig", .{}) catch break :blk false;
        collapse_file.close();
        const quantum_file = std.fs.cwd().openFile("deps/qstar-quantum/src/quantum.zig", .{}) catch break :blk false;
        quantum_file.close();
        const render_file = std.fs.cwd().openFile("deps/qstar-render/src/render.zig", .{}) catch break :blk false;
        render_file.close();
        break :blk true;
    };
    const full_deps_enabled = b.option(bool, "full-deps", "Enable all 8 qstar deps (mesh, net, transport, vfs, compress, collapse, quantum, render)") orelse full_deps_auto;

    // Dep module declarations (populated when deps are present)
    // Note: mesh, p2p_types, relay_router, nat, collapse, qr_nest, and transport_*
    // are now always available from src/ (ported from Abby/zotron/Qstar).
    var sybil_mod: ?*std.Build.Module = null;
    var merge_mod: ?*std.Build.Module = null;
    var maypole_bridge_mod: ?*std.Build.Module = null;
    var compress_dep_mod: ?*std.Build.Module = null;
    var turbo_quant_dep_mod: ?*std.Build.Module = null;
    var vfs_bridge_mod: ?*std.Build.Module = null;
    var vfs_streaming_mod: ?*std.Build.Module = null;
    var quantum_mod: ?*std.Build.Module = null;
    var entangle_mod: ?*std.Build.Module = null;
    var holographic_dep_mod: ?*std.Build.Module = null;
    var render_mod: ?*std.Build.Module = null;

    if (full_deps_enabled) {
        // mesh, p2p_types, relay_router, nat, collapse, qr_nest, transport_*
        // are now always available from src/ — only create non-ported dep modules here.
        sybil_mod = b.addModule("sybil", .{
            .root_source_file = b.path("deps/qstar-net/src/sybil.zig"),
            .target = target,
            .optimize = optimize,
        });
        merge_mod = b.addModule("merge", .{
            .root_source_file = b.path("deps/qstar-net/src/merge.zig"),
            .target = target,
            .optimize = optimize,
        });
        maypole_bridge_mod = b.addModule("maypole_bridge", .{
            .root_source_file = b.path("deps/qstar-transport/src/maypole_bridge.zig"),
            .target = target,
            .optimize = optimize,
        });
        compress_dep_mod = b.addModule("compress_dep", .{
            .root_source_file = b.path("deps/qstar-compress/src/compress.zig"),
            .target = target,
            .optimize = optimize,
        });
        turbo_quant_dep_mod = b.addModule("turbo_quant_dep", .{
            .root_source_file = b.path("deps/qstar-compress/src/turbo_quant.zig"),
            .target = target,
            .optimize = optimize,
        });
        vfs_bridge_mod = b.addModule("vfs_bridge", .{
            .root_source_file = b.path("deps/qstar-vfs/src/vfs_bridge.zig"),
            .target = target,
            .optimize = optimize,
        });
        vfs_streaming_mod = b.addModule("vfs_streaming", .{
            .root_source_file = b.path("deps/qstar-vfs/src/vfs_streaming.zig"),
            .target = target,
            .optimize = optimize,
        });
        quantum_mod = b.addModule("quantum", .{
            .root_source_file = b.path("deps/qstar-quantum/src/quantum.zig"),
            .target = target,
            .optimize = optimize,
        });
        entangle_mod = b.addModule("entangle", .{
            .root_source_file = b.path("deps/qstar-quantum/src/entangle.zig"),
            .target = target,
            .optimize = optimize,
        });
        holographic_dep_mod = b.addModule("holographic_dep", .{
            .root_source_file = b.path("deps/qstar-quantum/src/holographic.zig"),
            .target = target,
            .optimize = optimize,
        });
        render_mod = b.addModule("render", .{
            .root_source_file = b.path("deps/qstar-render/src/render.zig"),
            .target = target,
            .optimize = optimize,
        });
    }

    // Maple client module (always available — no external deps needed)
    const maple_client_mod = b.addModule("maple_client", .{
        .root_source_file = b.path("src/maple_client.zig"),
        .target = target,
        .optimize = optimize,
    });

    // --- Ported mesh/transport modules (always available — ported from Abby/zotron/Qstar) ---

    const mesh_mod = b.addModule("mesh", .{
        .root_source_file = b.path("src/mesh.zig"),
        .target = target,
        .optimize = optimize,
    });
    mesh_mod.addImport("fixed_point", fixed_point_mod);

    const p2p_types_mod = b.addModule("p2p_types", .{
        .root_source_file = b.path("src/p2p_types.zig"),
        .target = target,
        .optimize = optimize,
    });

    const relay_router_mod = b.addModule("relay_router", .{
        .root_source_file = b.path("src/relay_router.zig"),
        .target = target,
        .optimize = optimize,
    });
    relay_router_mod.addImport("p2p_types", p2p_types_mod);

    const nat_mod = b.addModule("nat", .{
        .root_source_file = b.path("src/nat.zig"),
        .target = target,
        .optimize = optimize,
    });

    const webrtc_mod = b.addModule("webrtc", .{
        .root_source_file = b.path("src/webrtc.zig"),
        .target = target,
        .optimize = optimize,
    });

    const mesh_peer_mod = b.addModule("mesh_peer", .{
        .root_source_file = b.path("src/mesh_peer.zig"),
        .target = target,
        .optimize = optimize,
    });
    mesh_peer_mod.addImport("mesh", mesh_mod);
    mesh_peer_mod.addImport("p2p_types", p2p_types_mod);
    mesh_peer_mod.addImport("relay_router", relay_router_mod);

    const qr_nest_mod = b.addModule("qr_nest", .{
        .root_source_file = b.path("src/qr_nest.zig"),
        .target = target,
        .optimize = optimize,
    });

    const collapse_mod = b.addModule("collapse", .{
        .root_source_file = b.path("src/collapse.zig"),
        .target = target,
        .optimize = optimize,
    });

    // --- Seed compressor module (collapse-driven seed compression pipeline) ---

    const seed_compressor_mod = b.addModule("seed_compressor", .{
        .root_source_file = b.path("src/seed_compressor.zig"),
        .target = target,
        .optimize = optimize,
    });
    seed_compressor_mod.addImport("fixed_point", fixed_point_mod);
    seed_compressor_mod.addImport("holographic", holographic_mod);
    seed_compressor_mod.addImport("compress", compress_mod);
    seed_compressor_mod.addImport("qr_nest", qr_nest_mod);
    seed_compressor_mod.addImport("fp_bridge", fp_bridge_mod);

    const transport_p2p_mod = b.addModule("transport_p2p", .{
        .root_source_file = b.path("src/transport_p2p.zig"),
        .target = target,
        .optimize = optimize,
    });

    const transport_wifi_mod = b.addModule("transport_wifi", .{
        .root_source_file = b.path("src/transport_wifi.zig"),
        .target = target,
        .optimize = optimize,
    });

    const transport_quine_mod = b.addModule("transport_quine", .{
        .root_source_file = b.path("src/transport_quine.zig"),
        .target = target,
        .optimize = optimize,
    });

    const transport_polyglot_mod = b.addModule("transport_polyglot", .{
        .root_source_file = b.path("src/transport_polyglot.zig"),
        .target = target,
        .optimize = optimize,
    });

    const transport_stega_mod = b.addModule("transport_stega", .{
        .root_source_file = b.path("src/transport_stega.zig"),
        .target = target,
        .optimize = optimize,
    });

    const transport_qr_mod = b.addModule("transport_qr", .{
        .root_source_file = b.path("src/transport_qr.zig"),
        .target = target,
        .optimize = optimize,
    });

    const transport_audio_mod = b.addModule("transport_audio", .{
        .root_source_file = b.path("src/transport_audio.zig"),
        .target = target,
        .optimize = optimize,
    });

    const transport_cassette_mod = b.addModule("transport_cassette", .{
        .root_source_file = b.path("src/transport_cassette.zig"),
        .target = target,
        .optimize = optimize,
    });

    const transport_convert_mod = b.addModule("transport_convert", .{
        .root_source_file = b.path("src/transport_convert.zig"),
        .target = target,
        .optimize = optimize,
    });

    const transport_lora_mod = b.addModule("transport_lora", .{
        .root_source_file = b.path("src/transport_lora.zig"),
        .target = target,
        .optimize = optimize,
    });

    const transport_optar_mod = b.addModule("transport_optar", .{
        .root_source_file = b.path("src/transport_optar.zig"),
        .target = target,
        .optimize = optimize,
    });

    const transport_paperback_mod = b.addModule("transport_paperback", .{
        .root_source_file = b.path("src/transport_paperback.zig"),
        .target = target,
        .optimize = optimize,
    });

    const transport_video_mod = b.addModule("transport_video", .{
        .root_source_file = b.path("src/transport_video.zig"),
        .target = target,
        .optimize = optimize,
    });

    const virtual_transport_mod = b.addModule("virtual_transport", .{
        .root_source_file = b.path("src/virtual_transport.zig"),
        .target = target,
        .optimize = optimize,
    });
    virtual_transport_mod.addImport("mesh", mesh_mod);

    // Helper to add a simple test with imports
    const TestSpec = struct {
        file: []const u8,
        imports: []const struct { name: []const u8, mod: *std.Build.Module },
        link_libc: bool = false,
    };

    const test_specs = [_]TestSpec{
        .{ .file = "src/fixed_point.zig", .imports = &.{} },
        .{ .file = "src/octonion_math.zig", .imports = &.{.{ .name = "fixed_point", .mod = fixed_point_mod }} },
        .{ .file = "src/hw_bridge.zig", .imports = &.{ .{ .name = "fixed_point", .mod = fixed_point_mod }, .{ .name = "octonion_math", .mod = octonion_math_mod } } },
        .{ .file = "src/sentience_scorer.zig", .imports = &.{} },
        .{ .file = "src/sentience_experiment.zig", .imports = &.{.{ .name = "sentience_scorer", .mod = sentience_scorer_mod }} },
        .{ .file = "src/holo_codec.zig", .imports = &.{} },
        .{ .file = "src/e8_roots.zig", .imports = &.{} },
        .{ .file = "src/jordan_algebra.zig", .imports = &.{.{ .name = "octonion_math", .mod = octonion_math_mod }} },
        .{ .file = "src/so10.zig", .imports = &.{} },
        .{ .file = "src/hardware_detect.zig", .imports = &.{} },
        .{ .file = "src/fixed_point32.zig", .imports = &.{} },
        .{ .file = "src/fp_bridge.zig", .imports = &.{ .{ .name = "fixed_point", .mod = fixed_point_mod }, .{ .name = "fixed_point32", .mod = fixed_point32_mod } } },
        .{ .file = "src/precision_scaler.zig", .imports = &.{ .{ .name = "fixed_point", .mod = fixed_point_mod }, .{ .name = "fixed_point32", .mod = fixed_point32_mod }, .{ .name = "fp_bridge", .mod = fp_bridge_mod }, .{ .name = "hardware_detect", .mod = hardware_detect_mod } } },
        .{ .file = "src/seed_compressor.zig", .imports = &.{ .{ .name = "fixed_point", .mod = fixed_point_mod }, .{ .name = "holographic", .mod = holographic_mod }, .{ .name = "compress", .mod = compress_mod }, .{ .name = "qr_nest", .mod = qr_nest_mod }, .{ .name = "fp_bridge", .mod = fp_bridge_mod } } },
        .{ .file = "src/lattice.zig", .imports = &.{} },
        .{ .file = "src/bpe_tokenizer.zig", .imports = &.{} },
        .{ .file = "src/sampling.zig", .imports = &.{} },
        .{ .file = "src/memory.zig", .imports = &.{} },
        .{ .file = "src/c_ffi.zig", .imports = &.{}, .link_libc = true },
        .{ .file = "src/vision/onnx_runtime.zig", .imports = &.{.{ .name = "c_ffi", .mod = c_ffi_mod }}, .link_libc = true },
        .{ .file = "src/vision/image.zig", .imports = &.{.{ .name = "c_ffi", .mod = c_ffi_mod }}, .link_libc = true },
        .{ .file = "src/vision/face_detect.zig", .imports = &.{.{ .name = "image", .mod = image_mod }} },
        .{ .file = "src/vision/face_recognize.zig", .imports = &.{ .{ .name = "image", .mod = image_mod }, .{ .name = "c_ffi", .mod = c_ffi_mod } }, .link_libc = true },
        .{ .file = "src/vision/face_landmark.zig", .imports = &.{.{ .name = "face_detect", .mod = face_detect_mod }} },
        .{ .file = "src/vision/face_track.zig", .imports = &.{.{ .name = "face_detect", .mod = face_detect_mod }} },
        .{ .file = "src/vision/gaze_headpose.zig", .imports = &.{ .{ .name = "face_detect", .mod = face_detect_mod }, .{ .name = "face_landmark", .mod = face_landmark_mod } } },
        .{ .file = "src/vision/face_attributes.zig", .imports = &.{} },
        .{ .file = "src/vision/face_parsing.zig", .imports = &.{ .{ .name = "image", .mod = image_mod }, .{ .name = "c_ffi", .mod = c_ffi_mod } }, .link_libc = true },
        .{ .file = "src/vision/face_quality.zig", .imports = &.{ .{ .name = "image", .mod = image_mod }, .{ .name = "face_detect", .mod = face_detect_mod }, .{ .name = "c_ffi", .mod = c_ffi_mod } }, .link_libc = true },
        .{ .file = "src/vision/anti_spoofing.zig", .imports = &.{ .{ .name = "image", .mod = image_mod }, .{ .name = "face_detect", .mod = face_detect_mod }, .{ .name = "c_ffi", .mod = c_ffi_mod } }, .link_libc = true },
        .{ .file = "src/vision/face_analyzer.zig", .imports = &.{
            .{ .name = "image", .mod = image_mod },
            .{ .name = "face_detect", .mod = face_detect_mod },
            .{ .name = "face_recognize", .mod = face_recognize_mod },
            .{ .name = "face_landmark", .mod = face_landmark_mod },
            .{ .name = "face_track", .mod = face_track_mod },
            .{ .name = "gaze_headpose", .mod = gaze_headpose_mod },
            .{ .name = "face_attributes", .mod = face_attributes_mod },
            .{ .name = "face_parsing", .mod = face_parsing_mod },
            .{ .name = "face_quality", .mod = face_quality_mod },
            .{ .name = "anti_spoofing", .mod = anti_spoofing_mod },
            .{ .name = "c_ffi", .mod = c_ffi_mod },
        }, .link_libc = true },
        .{ .file = "src/perception.zig", .imports = &.{.{ .name = "fixed_point", .mod = fixed_point_mod }} },
        // Geoview tests
        .{ .file = "src/geoview/geo_math.zig", .imports = &.{} },
        .{ .file = "src/geoview/globe_render.zig", .imports = &.{} },
        .{ .file = "src/geoview/camera.zig", .imports = &.{
            .{ .name = "geo_math", .mod = geo_math_mod },
            .{ .name = "globe_render", .mod = globe_render_mod },
        } },
        // Geoview feed tests
        .{ .file = "src/geoview/live_feeds.zig", .imports = &.{} },
        .{ .file = "src/geoview/feed_flights.zig", .imports = &.{.{ .name = "geo_math", .mod = geo_math_mod }} },
        .{ .file = "src/geoview/feed_vessels.zig", .imports = &.{.{ .name = "geo_math", .mod = geo_math_mod }} },
        .{ .file = "src/geoview/feed_satellites.zig", .imports = &.{.{ .name = "geo_math", .mod = geo_math_mod }} },
        .{ .file = "src/geoview/feed_earthquakes.zig", .imports = &.{} },
        .{ .file = "src/geoview/feed_traffic.zig", .imports = &.{} },
        .{ .file = "src/geoview/feed_cctv.zig", .imports = &.{.{ .name = "geo_math", .mod = geo_math_mod }} },
        // Geoview overlay/HUD tests
        .{ .file = "src/geoview/hud.zig", .imports = &.{} },
        .{ .file = "src/geoview/detection_overlay.zig", .imports = &.{} },
        .{ .file = "src/geoview/annotation.zig", .imports = &.{} },
        .{ .file = "src/geoview/scene_director.zig", .imports = &.{} },
        .{ .file = "src/geoview/styles.zig", .imports = &.{.{ .name = "hud", .mod = hud_mod }} },
        .{ .file = "src/geoview/voice_command.zig", .imports = &.{} },
        .{ .file = "src/knowledge_graph.zig", .imports = &.{
            .{ .name = "fixed_point", .mod = fixed_point_mod },
            .{ .name = "lattice", .mod = lattice_mod },
        } },
        .{ .file = "src/state_store.zig", .imports = &.{} },
        .{ .file = "src/face_sync.zig", .imports = &.{.{ .name = "fixed_point", .mod = fixed_point_mod }} },
        .{ .file = "src/ollama_client.zig", .imports = &.{} },
        .{ .file = "src/env_loader.zig", .imports = &.{} },
        .{ .file = "src/dynamic_dns.zig", .imports = &.{} },
        .{ .file = "src/llm_provider.zig", .imports = &.{
            .{ .name = "ollama_client", .mod = ollama_mod },
            .{ .name = "openai_client", .mod = openai_mod },
            .{ .name = "env_loader", .mod = env_loader_mod },
        } },
        .{ .file = "src/openai_client.zig", .imports = &.{} },
        .{ .file = "src/compress.zig", .imports = &.{} },
        .{ .file = "src/corpus_store.zig", .imports = &.{.{ .name = "compress", .mod = compress_mod }} },
        .{ .file = "src/build_html.zig", .imports = &.{
            .{ .name = "corpus_store", .mod = corpus_store_mod },
            .{ .name = "compress", .mod = compress_mod },
        } },
        .{ .file = "src/master_server.zig", .imports = &.{.{ .name = "dynamic_dns", .mod = dynamic_dns_mod }} },
        .{ .file = "src/master_publish.zig", .imports = &.{} },
        // p2p_update test is added conditionally after the loop (depends on -Dp2p)
        .{ .file = "src/doc_loader.zig", .imports = &.{} },
        .{ .file = "src/memory_pool.zig", .imports = &.{} },
        .{ .file = "src/config.zig", .imports = &.{.{ .name = "fixed_point", .mod = fixed_point_mod }} },
        .{ .file = "src/external_db.zig", .imports = &.{.{ .name = "knowledge_graph", .mod = kg_mod }} },
        .{ .file = "src/continual_learner.zig", .imports = &.{
            .{ .name = "knowledge_graph", .mod = kg_mod },
            .{ .name = "dynamic_routes", .mod = dynamic_routes_mod },
            .{ .name = "metacognition_engine", .mod = metacognition_engine_mod },
        } },
        .{ .file = "src/training.zig", .imports = &.{
            .{ .name = "agent", .mod = agent_mod },
            .{ .name = "ollama_client", .mod = ollama_mod },
            .{ .name = "openai_client", .mod = openai_mod },
            .{ .name = "doc_loader", .mod = doc_loader_mod },
            .{ .name = "corpus_store", .mod = corpus_store_mod },
            .{ .name = "fixed_point", .mod = fixed_point_mod },
            .{ .name = "prompt_generator", .mod = prompt_gen_test_mod },
        } },
        .{ .file = "src/heartbeat.zig", .imports = &.{
            .{ .name = "agent", .mod = agent_mod },
            .{ .name = "training", .mod = training_mod },
            .{ .name = "compress", .mod = compress_mod },
            .{ .name = "corpus_store", .mod = corpus_store_mod },
            .{ .name = "maple_client", .mod = maple_client_mod },
            .{ .name = "env_loader", .mod = env_loader_mod },
            .{ .name = "fixed_point", .mod = fixed_point_mod },
            .{ .name = "ollama_client", .mod = ollama_mod },
            .{ .name = "prompt_generator", .mod = prompt_gen_test_mod },
            .{ .name = "dynamic_routes", .mod = dynamic_routes_mod },
        } },
        .{ .file = "src/turing_test.zig", .imports = &.{
            .{ .name = "agent", .mod = agent_mod },
            .{ .name = "ollama_client", .mod = ollama_mod },
            .{ .name = "fixed_point", .mod = fixed_point_mod },
        } },
        .{ .file = "src/tools.zig", .imports = &.{
            .{ .name = "fixed_point", .mod = fixed_point_mod },
            .{ .name = "knowledge_graph", .mod = kg_mod },
            .{ .name = "external_db", .mod = external_db_mod },
            .{ .name = "geo_math", .mod = geo_math_mod },
        } },
        .{ .file = "src/server.zig", .imports = &.{
            .{ .name = "agent", .mod = agent_mod },
            .{ .name = "fixed_point", .mod = fixed_point_mod },
            .{ .name = "tools", .mod = tools_mod },
            .{ .name = "bpe_tokenizer", .mod = bpe_mod },
            .{ .name = "knowledge_graph", .mod = kg_mod },
            .{ .name = "external_db", .mod = external_db_mod },
            .{ .name = "turing_test", .mod = turing_test_mod },
        } },
        .{ .file = "src/holographic.zig", .imports = &.{.{ .name = "fixed_point", .mod = fixed_point_mod }} },
        .{ .file = "src/vulkan_compute.zig", .imports = &.{}, .link_libc = true },
        // Prototype tests
        //        .{ .file = "prototype/discourse_agent.zig", .imports = &.{} },
        //        .{ .file = "prototype/turbo_quant.zig", .imports = &.{} },
        //        .{ .file = "prototype/samc_lattice.zig", .imports = &.{} },
        ////        .{ .file = "prototype/samc_agent.zig", .imports = &.{.{ .name = "samc_lattice", .mod = samc_lattice_mod }} },
        //        .{ .file = "prototype/vocab_loader.zig", .imports = &.{} },
        //        .{ .file = "prototype/vocab_lattice_scaling.zig", .imports = &.{} },
        //        .{ .file = "prototype/lattice_context.zig", .imports = &.{} },
        //        .{ .file = "prototype/agent_int.zig", .imports = &.{.{ .name = "fixed_point", .mod = fixed_point_mod }} },
        //        .{ .file = "prototype/holographic_int.zig", .imports = &.{.{ .name = "fixed_point", .mod = fixed_point_mod }} },
        //        .{ .file = "prototype/quantum_int.zig", .imports = &.{.{ .name = "fixed_point", .mod = fixed_point_mod }} },
        //        .{ .file = "prototype/mesh_int.zig", .imports = &.{.{ .name = "fixed_point", .mod = fixed_point_mod }} },
        //        .{ .file = "prototype/s0_projection.zig", .imports = &.{
        //            .{ .name = "fixed_point", .mod = fixed_point_mod },
        //            .{ .name = "holographic", .mod = holographic_mod },
        //            .{ .name = "turbo_quant", .mod = turbo_quant_mod },
        //        } },
        //        .{ .file = "prototype/s7_compression.zig", .imports = &.{
        //            .{ .name = "fixed_point", .mod = fixed_point_mod },
        //            .{ .name = "holographic", .mod = holographic_mod },
        //        } },
        .{ .file = "src/codon.zig", .imports = &.{} },
        // Ported mesh/transport modules
        .{ .file = "src/mesh.zig", .imports = &.{.{ .name = "fixed_point", .mod = fixed_point_mod }} },
        .{ .file = "src/p2p_types.zig", .imports = &.{} },
        .{ .file = "src/relay_router.zig", .imports = &.{.{ .name = "p2p_types", .mod = p2p_types_mod }} },
        .{ .file = "src/nat.zig", .imports = &.{} },
        .{ .file = "src/webrtc.zig", .imports = &.{} },
        .{ .file = "src/mesh_peer.zig", .imports = &.{
            .{ .name = "mesh", .mod = mesh_mod },
            .{ .name = "p2p_types", .mod = p2p_types_mod },
            .{ .name = "relay_router", .mod = relay_router_mod },
        } },
        .{ .file = "src/qr_nest.zig", .imports = &.{} },
        .{ .file = "src/collapse.zig", .imports = &.{} },
        .{ .file = "src/transport_p2p.zig", .imports = &.{} },
        .{ .file = "src/transport_wifi.zig", .imports = &.{} },
        .{ .file = "src/transport_quine.zig", .imports = &.{} },
        .{ .file = "src/transport_polyglot.zig", .imports = &.{} },
        .{ .file = "src/transport_stega.zig", .imports = &.{} },
        .{ .file = "src/transport_qr.zig", .imports = &.{} },
        .{ .file = "src/transport_audio.zig", .imports = &.{} },
        .{ .file = "src/transport_cassette.zig", .imports = &.{} },
        .{ .file = "src/transport_convert.zig", .imports = &.{} },
        .{ .file = "src/transport_lora.zig", .imports = &.{} },
        .{ .file = "src/transport_optar.zig", .imports = &.{} },
        .{ .file = "src/transport_paperback.zig", .imports = &.{} },
        .{ .file = "src/transport_video.zig", .imports = &.{} },
        .{ .file = "src/virtual_transport.zig", .imports = &.{.{ .name = "mesh", .mod = mesh_mod }} },
        .{ .file = "src/metacognition_engine.zig", .imports = &.{
            .{ .name = "dynamic_routes", .mod = dynamic_routes_mod },
            .{ .name = "hw_bridge", .mod = hw_bridge_mod },
        } },
        .{ .file = "src/dynamic_routes.zig", .imports = &.{} },
        .{ .file = "src/trivium.zig", .imports = &.{} },
        .{ .file = "src/quadrivium.zig", .imports = &.{.{ .name = "fixed_point", .mod = fixed_point_mod }} },
        .{ .file = "src/q128.zig", .imports = &.{} },
        .{ .file = "src/corpus_learner.zig", .imports = &.{
            .{ .name = "trivium", .mod = trivium_mod },
            .{ .name = "quadrivium", .mod = quadrivium_mod },
            .{ .name = "dynamic_routes", .mod = dynamic_routes_mod },
        } },
        .{ .file = "src/voice_codec.zig", .imports = &.{.{ .name = "fixed_point", .mod = fixed_point_mod }} },
        .{ .file = "src/cognitive_cloud.zig", .imports = &.{.{ .name = "fixed_point", .mod = fixed_point_mod }} },
        .{ .file = "src/holographic_memory.zig", .imports = &.{ .{ .name = "fixed_point", .mod = fixed_point_mod }, .{ .name = "cognitive_cloud", .mod = cognitive_cloud_mod } } },
    };

    var prev_test_step: ?*std.Build.Step = null;
    for (test_specs) |spec| {
        const t = b.addTest(.{
            .root_source_file = b.path(spec.file),
            .target = target,
            .optimize = optimize,
            .link_libc = spec.link_libc,
        });
        for (spec.imports) |imp| {
            t.root_module.addImport(imp.name, imp.mod);
        }
        const run_step = &b.addRunArtifact(t).step;
        if (prev_test_step) |prev| {
            run_step.dependOn(prev);
        }
        test_step.dependOn(run_step);
        prev_test_step = run_step;
    }

    // Agent tests (the big one — 88 tests) — needs separate module instances to avoid conflicts
    const agent_tests = b.addTest(.{
        .root_source_file = b.path("src/agent.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    agent_tests.root_module.addImport("bpe_tokenizer", bpe_mod);
    agent_tests.root_module.addImport("sampling", sampling_mod);
    agent_tests.root_module.addImport("state_store", state_store_mod);
    agent_tests.root_module.addImport("face_sync", face_sync_mod);
    agent_tests.root_module.addImport("fixed_point", fixed_point_mod);
    agent_tests.root_module.addImport("q128", q128_mod);
    const agent_kg_mod = b.addModule("knowledge_graph", .{
        .root_source_file = b.path("src/knowledge_graph.zig"),
        .target = target,
        .optimize = optimize,
    });
    agent_kg_mod.addImport("fixed_point", fixed_point_mod);
    const agent_lattice_for_kg = b.addModule("lattice", .{
        .root_source_file = b.path("src/lattice.zig"),
        .target = target,
        .optimize = optimize,
    });
    agent_lattice_for_kg.addImport("fixed_point", fixed_point_mod);
    agent_kg_mod.addImport("lattice", agent_lattice_for_kg);
    agent_tests.root_module.addImport("knowledge_graph", agent_kg_mod);
    const agent_mem_mod = b.addModule("memory", .{
        .root_source_file = b.path("src/memory.zig"),
        .target = target,
        .optimize = optimize,
    });
    agent_tests.root_module.addImport("memory", agent_mem_mod);
    const agent_perception_mod = b.addModule("perception", .{
        .root_source_file = b.path("src/perception.zig"),
        .target = target,
        .optimize = optimize,
    });
    agent_perception_mod.addImport("fixed_point", fixed_point_mod);
    agent_tests.root_module.addImport("perception", agent_perception_mod);
    const agent_metacog_mod = b.addModule("metacognition_engine", .{
        .root_source_file = b.path("src/metacognition_engine.zig"),
        .target = target,
        .optimize = optimize,
    });
    agent_tests.root_module.addImport("metacognition_engine", agent_metacog_mod);
    const agent_dyn_routes_mod = b.addModule("dynamic_routes", .{
        .root_source_file = b.path("src/dynamic_routes.zig"),
        .target = target,
        .optimize = optimize,
    });
    agent_metacog_mod.addImport("dynamic_routes", agent_dyn_routes_mod);
    agent_metacog_mod.addImport("hw_bridge", hw_bridge_mod);
    agent_metacog_mod.addImport("q128", q128_mod);
    agent_tests.root_module.addImport("dynamic_routes", agent_dyn_routes_mod);
    const agent_trivium_mod = b.addModule("trivium", .{
        .root_source_file = b.path("src/trivium.zig"),
        .target = target,
        .optimize = optimize,
    });
    agent_tests.root_module.addImport("trivium", agent_trivium_mod);
    const agent_quadrivium_mod = b.addModule("quadrivium", .{
        .root_source_file = b.path("src/quadrivium.zig"),
        .target = target,
        .optimize = optimize,
    });
    agent_quadrivium_mod.addImport("fixed_point", fixed_point_mod);
    agent_tests.root_module.addImport("quadrivium", agent_quadrivium_mod);
    const agent_corpus_learner_mod = b.addModule("corpus_learner", .{
        .root_source_file = b.path("src/corpus_learner.zig"),
        .target = target,
        .optimize = optimize,
    });
    agent_corpus_learner_mod.addImport("trivium", agent_trivium_mod);
    agent_corpus_learner_mod.addImport("quadrivium", agent_quadrivium_mod);
    agent_corpus_learner_mod.addImport("dynamic_routes", agent_dyn_routes_mod);
    agent_tests.root_module.addImport("corpus_learner", agent_corpus_learner_mod);
    const agent_cognitive_cloud_mod = b.addModule("cognitive_cloud", .{
        .root_source_file = b.path("src/cognitive_cloud.zig"),
        .target = target,
        .optimize = optimize,
    });
    agent_cognitive_cloud_mod.addImport("fixed_point", fixed_point_mod);
    agent_tests.root_module.addImport("cognitive_cloud", agent_cognitive_cloud_mod);
    const agent_voice_codec_mod = b.addModule("voice_codec", .{
        .root_source_file = b.path("src/voice_codec.zig"),
        .target = target,
        .optimize = optimize,
    });
    agent_voice_codec_mod.addImport("fixed_point", fixed_point_mod);
    agent_tests.root_module.addImport("voice_codec", agent_voice_codec_mod);
    const agent_vk_mod = b.addModule("vulkan_compute", .{
        .root_source_file = b.path("src/vulkan_compute.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    agent_tests.root_module.addImport("vulkan_compute", agent_vk_mod);
    agent_tests.root_module.addImport("lattice", agent_lattice_for_kg);
    agent_tests.root_module.addImport("hw_bridge", hw_bridge_mod);
    const agent_corpus_seed_mod = b.addModule("corpus_seed", .{
        .root_source_file = b.path("src/corpus_seed.zig"),
        .target = target,
        .optimize = optimize,
    });
    agent_tests.root_module.addImport("corpus_seed", agent_corpus_seed_mod);
    const agent_tools_mod = b.addModule("tools", .{
        .root_source_file = b.path("src/tools.zig"),
        .target = target,
        .optimize = optimize,
    });
    agent_tools_mod.addImport("fixed_point", fixed_point_mod);
    agent_tools_mod.addImport("knowledge_graph", agent_kg_mod);
    const agent_ext_db_mod = b.addModule("external_db", .{
        .root_source_file = b.path("src/external_db.zig"),
        .target = target,
        .optimize = optimize,
    });
    agent_ext_db_mod.addImport("knowledge_graph", agent_kg_mod);
    agent_tools_mod.addImport("external_db", agent_ext_db_mod);
    const agent_geo_math_mod = b.addModule("geo_math", .{
        .root_source_file = b.path("src/geoview/geo_math.zig"),
        .target = target,
        .optimize = optimize,
    });
    agent_tools_mod.addImport("geo_math", agent_geo_math_mod);
    agent_tests.root_module.addImport("tools", agent_tools_mod);
    const agent_test_run = &b.addRunArtifact(agent_tests).step;
    if (prev_test_step) |prev| agent_test_run.dependOn(prev);
    test_step.dependOn(agent_test_run);
    prev_test_step = agent_test_run;

    // Prompt generator tests (Ollama-based prompt generation)
    const pg_ollama_mod = b.addModule("ollama_client", .{
        .root_source_file = b.path("src/ollama_client.zig"),
        .target = target,
        .optimize = optimize,
    });
    const prompt_gen_tests = b.addTest(.{
        .root_source_file = b.path("src/prompt_generator.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    prompt_gen_tests.root_module.addImport("ollama_client", pg_ollama_mod);
    const pg_test_run = &b.addRunArtifact(prompt_gen_tests).step;
    if (prev_test_step) |prev| pg_test_run.dependOn(prev);
    test_step.dependOn(pg_test_run);
    prev_test_step = pg_test_run;

    // Agent lite tests (device-lite variant — 30 tests)
    const agent_lite_tests = b.addTest(.{
        .root_source_file = b.path("src/agent_lite.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    agent_lite_tests.root_module.addImport("fixed_point", fixed_point_mod);
    const agent_lite_corpus_mod = b.addModule("corpus_seed", .{
        .root_source_file = b.path("src/corpus_seed_lite.zig"),
        .target = target,
        .optimize = optimize,
    });
    agent_lite_tests.root_module.addImport("corpus_seed", agent_lite_corpus_mod);
    const lite_test_run = &b.addRunArtifact(agent_lite_tests).step;
    if (prev_test_step) |prev| lite_test_run.dependOn(prev);
    test_step.dependOn(lite_test_run);
    prev_test_step = lite_test_run;

    // === Individual test steps (workaround for Zig 0.13.0 listen protocol deadlock) ===

    const test_turing_step = b.step("test-turing", "Run only turing_test tests");
    const turing_test_bin = b.addTest(.{
        .root_source_file = b.path("src/turing_test.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    turing_test_bin.root_module.addImport("agent", agent_mod);
    turing_test_bin.root_module.addImport("ollama_client", ollama_mod);
    turing_test_bin.root_module.addImport("fixed_point", fixed_point_mod);
    turing_test_bin.root_module.addImport("q128", q128_mod);
    test_turing_step.dependOn(&b.addRunArtifact(turing_test_bin).step);

    const test_agent_step = b.step("test-agent", "Run only agent tests");
    test_agent_step.dependOn(agent_test_run);

    // === Example Executable ===

    const exe = b.addExecutable(.{
        .name = "qstar-llm",
        .root_source_file = b.path("examples/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    exe.root_module.addImport("agent", agent_mod);
    exe.root_module.addImport("fixed_point", fixed_point_mod);
    exe.root_module.addImport("bpe_tokenizer", bpe_mod);
    exe.root_module.addImport("sampling", sampling_mod);
    exe.root_module.addImport("state_store", state_store_mod);
    exe.root_module.addImport("face_sync", face_sync_mod);
    exe.root_module.addImport("knowledge_graph", kg_mod);
    exe.root_module.addImport("memory", memory_mod);
    exe.root_module.addImport("perception", perception_mod);
    exe.root_module.addImport("ollama_client", ollama_mod);
    exe.root_module.addImport("doc_loader", doc_loader_mod);
    exe.root_module.addImport("training", training_mod);
    exe.root_module.addImport("turing_test", turing_test_mod);
    exe.root_module.addImport("tools", tools_mod);
    exe.root_module.addImport("external_db", external_db_mod);
    exe.root_module.addImport("config", config_mod);
    exe.root_module.addImport("memory_pool", memory_pool_mod);

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run the example");
    run_step.dependOn(&run_cmd.step);

    // === CLI Binary ===

    const cli_mod = b.addModule("agent", .{
        .root_source_file = b.path("src/agent.zig"),
        .target = target,
        .optimize = optimize,
    });
    cli_mod.addImport("bpe_tokenizer", bpe_mod);
    cli_mod.addImport("sampling", sampling_mod);
    cli_mod.addImport("state_store", state_store_mod);
    cli_mod.addImport("face_sync", face_sync_mod);
    cli_mod.addImport("fixed_point", fixed_point_mod);
    cli_mod.addImport("q128", q128_mod);
    const cli_kg_mod = b.addModule("knowledge_graph", .{
        .root_source_file = b.path("src/knowledge_graph.zig"),
        .target = target,
        .optimize = optimize,
    });
    cli_kg_mod.addImport("fixed_point", fixed_point_mod);
    const cli_lattice_mod = b.addModule("lattice", .{
        .root_source_file = b.path("src/lattice.zig"),
        .target = target,
        .optimize = optimize,
    });
    cli_kg_mod.addImport("lattice", cli_lattice_mod);
    cli_mod.addImport("lattice", cli_lattice_mod);
    cli_mod.addImport("knowledge_graph", cli_kg_mod);
    cli_mod.addImport("corpus_seed", corpus_seed_mod);
    const cli_mem_mod = b.addModule("memory", .{
        .root_source_file = b.path("src/memory.zig"),
        .target = target,
        .optimize = optimize,
    });
    cli_mod.addImport("memory", cli_mem_mod);
    const cli_perc_mod = b.addModule("perception", .{
        .root_source_file = b.path("src/perception.zig"),
        .target = target,
        .optimize = optimize,
    });
    cli_perc_mod.addImport("fixed_point", fixed_point_mod);
    cli_mod.addImport("perception", cli_perc_mod);
    const cli_metacog_mod = b.addModule("metacognition_engine", .{
        .root_source_file = b.path("src/metacognition_engine.zig"),
        .target = target,
        .optimize = optimize,
    });
    cli_mod.addImport("metacognition_engine", cli_metacog_mod);
    const cli_dyn_routes_mod = b.addModule("dynamic_routes", .{
        .root_source_file = b.path("src/dynamic_routes.zig"),
        .target = target,
        .optimize = optimize,
    });
    cli_metacog_mod.addImport("dynamic_routes", cli_dyn_routes_mod);
    cli_metacog_mod.addImport("hw_bridge", hw_bridge_mod);
    cli_metacog_mod.addImport("q128", q128_mod);
    cli_mod.addImport("dynamic_routes", cli_dyn_routes_mod);
    const cli_trivium_mod = b.addModule("trivium", .{
        .root_source_file = b.path("src/trivium.zig"),
        .target = target,
        .optimize = optimize,
    });
    cli_mod.addImport("trivium", cli_trivium_mod);
    const cli_quadrivium_mod = b.addModule("quadrivium", .{
        .root_source_file = b.path("src/quadrivium.zig"),
        .target = target,
        .optimize = optimize,
    });
    cli_quadrivium_mod.addImport("fixed_point", fixed_point_mod);
    cli_mod.addImport("quadrivium", cli_quadrivium_mod);
    const cli_corpus_learner_mod = b.addModule("corpus_learner", .{
        .root_source_file = b.path("src/corpus_learner.zig"),
        .target = target,
        .optimize = optimize,
    });
    cli_corpus_learner_mod.addImport("trivium", cli_trivium_mod);
    cli_corpus_learner_mod.addImport("quadrivium", cli_quadrivium_mod);
    cli_corpus_learner_mod.addImport("dynamic_routes", cli_dyn_routes_mod);
    cli_mod.addImport("corpus_learner", cli_corpus_learner_mod);
    const cli_voice_codec_mod = b.addModule("voice_codec", .{
        .root_source_file = b.path("src/voice_codec.zig"),
        .target = target,
        .optimize = optimize,
    });
    cli_voice_codec_mod.addImport("fixed_point", fixed_point_mod);
    cli_mod.addImport("voice_codec", cli_voice_codec_mod);
    const cli_vk_mod = b.addModule("vulkan_compute", .{
        .root_source_file = b.path("src/vulkan_compute.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    cli_mod.addImport("vulkan_compute", cli_vk_mod);
    cli_mod.addImport("hw_bridge", hw_bridge_mod);

    const cli_ollama_mod = b.addModule("ollama_client", .{
        .root_source_file = b.path("src/ollama_client.zig"),
        .target = target,
        .optimize = optimize,
    });
    const cli_llm_provider_mod = b.addModule("llm_provider", .{
        .root_source_file = b.path("src/llm_provider.zig"),
        .target = target,
        .optimize = optimize,
    });
    cli_llm_provider_mod.addImport("ollama_client", cli_ollama_mod);
    cli_llm_provider_mod.addImport("openai_client", openai_mod);
    cli_llm_provider_mod.addImport("env_loader", env_loader_mod);
    const cli_doc_loader_mod = b.addModule("doc_loader", .{
        .root_source_file = b.path("src/doc_loader.zig"),
        .target = target,
        .optimize = optimize,
    });
    const cli_external_db_mod = b.addModule("external_db", .{
        .root_source_file = b.path("src/external_db.zig"),
        .target = target,
        .optimize = optimize,
    });
    cli_external_db_mod.addImport("knowledge_graph", cli_kg_mod);

    const cli_training_mod = b.addModule("training", .{
        .root_source_file = b.path("src/training.zig"),
        .target = target,
        .optimize = optimize,
    });
    cli_training_mod.addImport("agent", cli_mod);
    cli_training_mod.addImport("ollama_client", cli_ollama_mod);
    cli_training_mod.addImport("openai_client", openai_mod);
    cli_training_mod.addImport("doc_loader", cli_doc_loader_mod);
    cli_training_mod.addImport("corpus_store", corpus_store_mod);
    cli_training_mod.addImport("fixed_point", fixed_point_mod);
    const cli_prompt_gen_mod = b.addModule("prompt_generator", .{
        .root_source_file = b.path("src/prompt_generator.zig"),
        .target = target,
        .optimize = optimize,
    });
    cli_prompt_gen_mod.addImport("ollama_client", cli_ollama_mod);
    cli_training_mod.addImport("prompt_generator", cli_prompt_gen_mod);

    const cli_turing_mod = b.addModule("turing_test", .{
        .root_source_file = b.path("src/turing_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    cli_turing_mod.addImport("agent", cli_mod);
    cli_turing_mod.addImport("ollama_client", cli_ollama_mod);
    cli_turing_mod.addImport("fixed_point", fixed_point_mod);
    cli_turing_mod.addImport("q128", q128_mod);

    const cli_tools_mod = b.addModule("tools", .{
        .root_source_file = b.path("src/tools.zig"),
        .target = target,
        .optimize = optimize,
    });
    cli_tools_mod.addImport("fixed_point", fixed_point_mod);
    cli_tools_mod.addImport("knowledge_graph", cli_kg_mod);
    cli_tools_mod.addImport("external_db", cli_external_db_mod);
    cli_tools_mod.addImport("geo_math", geo_math_mod);

    cli_mod.addImport("tools", cli_tools_mod);

    const cli_server_mod = b.addModule("server", .{
        .root_source_file = b.path("src/server.zig"),
        .target = target,
        .optimize = optimize,
    });
    cli_server_mod.addImport("agent", cli_mod);
    cli_server_mod.addImport("fixed_point", fixed_point_mod);
    cli_server_mod.addImport("tools", cli_tools_mod);
    cli_server_mod.addImport("bpe_tokenizer", bpe_mod);
    cli_server_mod.addImport("knowledge_graph", cli_kg_mod);
    cli_server_mod.addImport("external_db", cli_external_db_mod);
    cli_server_mod.addImport("turing_test", cli_turing_mod);
    cli_server_mod.addImport("corpus_seed", corpus_seed_mod);

    const cli_cl_mod = b.addModule("continual_learner", .{
        .root_source_file = b.path("src/continual_learner.zig"),
        .target = target,
        .optimize = optimize,
    });
    cli_cl_mod.addImport("knowledge_graph", cli_kg_mod);
    cli_cl_mod.addImport("dynamic_routes", cli_dyn_routes_mod);
    cli_cl_mod.addImport("metacognition_engine", cli_metacog_mod);

    const cli_exe = b.addExecutable(.{
        .name = "qstar",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    cli_exe.root_module.addImport("agent", cli_mod);
    cli_exe.root_module.addImport("fixed_point", fixed_point_mod);
    cli_exe.root_module.addImport("q128", q128_mod);
    cli_exe.root_module.addImport("server", cli_server_mod);
    cli_exe.root_module.addImport("tools", cli_tools_mod);
    cli_exe.root_module.addImport("bpe_tokenizer", bpe_mod);
    cli_exe.root_module.addImport("training", cli_training_mod);
    cli_exe.root_module.addImport("ollama_client", cli_ollama_mod);
    cli_exe.root_module.addImport("openai_client", openai_mod);
    cli_exe.root_module.addImport("env_loader", env_loader_mod);
    cli_exe.root_module.addImport("dynamic_dns", dynamic_dns_mod);
    cli_exe.root_module.addImport("llm_provider", cli_llm_provider_mod);
    cli_exe.root_module.addImport("compress", compress_mod);
    cli_exe.root_module.addImport("corpus_store", corpus_store_mod);
    cli_exe.root_module.addImport("doc_loader", cli_doc_loader_mod);
    cli_exe.root_module.addImport("knowledge_graph", cli_kg_mod);
    cli_exe.root_module.addImport("external_db", cli_external_db_mod);
    cli_exe.root_module.addImport("continual_learner", cli_cl_mod);
    cli_exe.root_module.addImport("turing_test", cli_turing_mod);
    cli_exe.root_module.addImport("master_server", master_server_mod);
    if (p2p_enabled) {
        cli_exe.root_module.addImport("p2p_update", p2p_update_mod);
    }
    cli_exe.root_module.addImport("geo_math", geo_math_mod);
    cli_exe.root_module.addImport("mesh", mesh_mod);
    cli_exe.root_module.addImport("p2p_types", p2p_types_mod);
    cli_exe.root_module.addImport("relay_router", relay_router_mod);
    cli_exe.root_module.addImport("nat", nat_mod);
    cli_exe.root_module.addImport("webrtc", webrtc_mod);
    cli_exe.root_module.addImport("mesh_peer", mesh_peer_mod);
    cli_exe.root_module.addImport("collapse", collapse_mod);
    cli_exe.root_module.addImport("qr_nest", qr_nest_mod);
    cli_exe.root_module.addImport("hw_bridge", hw_bridge_mod);
    cli_exe.root_module.addImport("lattice", cli_lattice_mod);
    cli_exe.root_module.addImport("transport_p2p", transport_p2p_mod);
    cli_exe.root_module.addImport("transport_wifi", transport_wifi_mod);
    cli_exe.root_module.addImport("transport_quine", transport_quine_mod);
    cli_exe.root_module.addImport("transport_polyglot", transport_polyglot_mod);
    cli_exe.root_module.addImport("transport_stega", transport_stega_mod);
    cli_exe.root_module.addImport("transport_qr", transport_qr_mod);
    cli_exe.root_module.addImport("transport_audio", transport_audio_mod);
    cli_exe.root_module.addImport("transport_cassette", transport_cassette_mod);
    cli_exe.root_module.addImport("transport_convert", transport_convert_mod);
    cli_exe.root_module.addImport("transport_lora", transport_lora_mod);
    cli_exe.root_module.addImport("transport_optar", transport_optar_mod);
    cli_exe.root_module.addImport("transport_paperback", transport_paperback_mod);
    cli_exe.root_module.addImport("transport_video", transport_video_mod);
    cli_exe.root_module.addImport("virtual_transport", virtual_transport_mod);
    cli_exe.root_module.addImport("seed_compressor", seed_compressor_mod);

    // Pass build_options to CLI so it can conditionally compile P2P code
    const cli_options = b.addOptions();
    cli_options.addOption(bool, "p2p_enabled", p2p_enabled);
    cli_exe.root_module.addOptions("build_options", cli_options);

    b.installArtifact(cli_exe);

    const cli_run = b.addRunArtifact(cli_exe);
    if (b.args) |args| cli_run.addArgs(args);
    const cli_step = b.step("cli", "Run the CLI binary");
    cli_step.dependOn(&cli_run.step);

    // === Serve Step ===

    const serve_step = b.step("serve", "Run the HTTP API server");
    const serve_cmd = b.addRunArtifact(cli_exe);
    serve_cmd.addArg("serve");
    if (b.args) |args| serve_cmd.addArgs(args);
    serve_step.dependOn(&serve_cmd.step);

    // === Ollama Benchmark Step ===

    const ollama_bench_step = b.step("ollama-bench", "Run live head-to-head benchmark against running Ollama");
    {
        const ob_exe = b.addExecutable(.{
            .name = "ollama_benchmark",
            .root_source_file = b.path("tests/ollama_benchmark.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        ob_exe.root_module.addImport("fixed_point", fixed_point_mod);
        ob_exe.root_module.addImport("sampling", sampling_mod);
        // Agent needs its own module instance for the executable
        const ob_agent_mod = b.addModule("agent", .{
            .root_source_file = b.path("src/agent.zig"),
            .target = target,
            .optimize = optimize,
        });
        ob_agent_mod.addImport("fixed_point", fixed_point_mod);
        ob_agent_mod.addImport("q128", q128_mod);
        ob_agent_mod.addImport("bpe_tokenizer", bpe_mod);
        ob_agent_mod.addImport("sampling", sampling_mod);
        ob_agent_mod.addImport("state_store", state_store_mod);
        ob_agent_mod.addImport("face_sync", face_sync_mod);
        const ob_kg_mod = b.addModule("knowledge_graph", .{
            .root_source_file = b.path("src/knowledge_graph.zig"),
            .target = target,
            .optimize = optimize,
        });
        ob_kg_mod.addImport("fixed_point", fixed_point_mod);
        const ob_lat_mod = b.addModule("lattice", .{
            .root_source_file = b.path("src/lattice.zig"),
            .target = target,
            .optimize = optimize,
        });
        ob_kg_mod.addImport("lattice", ob_lat_mod);
        ob_agent_mod.addImport("lattice", ob_lat_mod);
        ob_agent_mod.addImport("knowledge_graph", ob_kg_mod);
        ob_agent_mod.addImport("corpus_seed", corpus_seed_mod);
        const ob_mem_mod = b.addModule("memory", .{
            .root_source_file = b.path("src/memory.zig"),
            .target = target,
            .optimize = optimize,
        });
        ob_agent_mod.addImport("memory", ob_mem_mod);
        const ob_perc_mod = b.addModule("perception", .{
            .root_source_file = b.path("src/perception.zig"),
            .target = target,
            .optimize = optimize,
        });
        ob_perc_mod.addImport("fixed_point", fixed_point_mod);
        ob_agent_mod.addImport("perception", ob_perc_mod);
        const ob_metacog_mod = b.addModule("metacognition_engine", .{
            .root_source_file = b.path("src/metacognition_engine.zig"),
            .target = target,
            .optimize = optimize,
        });
        ob_agent_mod.addImport("metacognition_engine", ob_metacog_mod);
        const ob_dyn_routes_mod = b.addModule("dynamic_routes", .{
            .root_source_file = b.path("src/dynamic_routes.zig"),
            .target = target,
            .optimize = optimize,
        });
        ob_metacog_mod.addImport("dynamic_routes", ob_dyn_routes_mod);
        ob_metacog_mod.addImport("q128", q128_mod);
        ob_agent_mod.addImport("dynamic_routes", ob_dyn_routes_mod);
        const ob_trivium_mod = b.addModule("trivium", .{
            .root_source_file = b.path("src/trivium.zig"),
            .target = target,
            .optimize = optimize,
        });
        ob_agent_mod.addImport("trivium", ob_trivium_mod);
        const ob_quadrivium_mod = b.addModule("quadrivium", .{
            .root_source_file = b.path("src/quadrivium.zig"),
            .target = target,
            .optimize = optimize,
        });
        ob_quadrivium_mod.addImport("fixed_point", fixed_point_mod);
        ob_agent_mod.addImport("quadrivium", ob_quadrivium_mod);
        const ob_corpus_learner_mod = b.addModule("corpus_learner", .{
            .root_source_file = b.path("src/corpus_learner.zig"),
            .target = target,
            .optimize = optimize,
        });
        ob_corpus_learner_mod.addImport("trivium", ob_trivium_mod);
        ob_corpus_learner_mod.addImport("quadrivium", ob_quadrivium_mod);
        ob_corpus_learner_mod.addImport("dynamic_routes", ob_dyn_routes_mod);
        ob_agent_mod.addImport("corpus_learner", ob_corpus_learner_mod);
        const ob_voice_codec_mod = b.addModule("voice_codec", .{
            .root_source_file = b.path("src/voice_codec.zig"),
            .target = target,
            .optimize = optimize,
        });
        ob_voice_codec_mod.addImport("fixed_point", fixed_point_mod);
        ob_agent_mod.addImport("voice_codec", ob_voice_codec_mod);
        const ob_vk_mod = b.addModule("vulkan_compute", .{
            .root_source_file = b.path("src/vulkan_compute.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        ob_agent_mod.addImport("vulkan_compute", ob_vk_mod);

        // Tools module for ollama bench agent
        const ob_tools_mod = b.addModule("tools", .{
            .root_source_file = b.path("src/tools.zig"),
            .target = target,
            .optimize = optimize,
        });
        ob_tools_mod.addImport("fixed_point", fixed_point_mod);
        ob_tools_mod.addImport("knowledge_graph", ob_kg_mod);
        const ob_ext_db_mod = b.addModule("external_db", .{
            .root_source_file = b.path("src/external_db.zig"),
            .target = target,
            .optimize = optimize,
        });
        ob_ext_db_mod.addImport("knowledge_graph", ob_kg_mod);
        ob_tools_mod.addImport("external_db", ob_ext_db_mod);
        const ob_geo_math_mod = b.addModule("geo_math", .{
            .root_source_file = b.path("src/geoview/geo_math.zig"),
            .target = target,
            .optimize = optimize,
        });
        ob_tools_mod.addImport("geo_math", ob_geo_math_mod);
        ob_agent_mod.addImport("tools", ob_tools_mod);

        ob_exe.root_module.addImport("agent", ob_agent_mod);
        ob_exe.root_module.addImport("env_loader", env_loader_mod);
        ob_exe.root_module.addImport("llm_provider", llm_provider_mod);
        ollama_bench_step.dependOn(&b.addRunArtifact(ob_exe).step);
    }

    // === Audit Agent Step ===

    const audit_step = b.step("audit", "Run agent dual-mode audit");
    {
        const au_exe = b.addExecutable(.{
            .name = "audit_agent",
            .root_source_file = b.path("tests/audit_agent.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        au_exe.root_module.addImport("fixed_point", fixed_point_mod);
        au_exe.root_module.addImport("bpe_tokenizer", bpe_mod);
        const au_agent_mod = b.addModule("agent", .{
            .root_source_file = b.path("src/agent.zig"),
            .target = target,
            .optimize = optimize,
        });
        au_agent_mod.addImport("fixed_point", fixed_point_mod);
        au_agent_mod.addImport("q128", q128_mod);
        au_agent_mod.addImport("bpe_tokenizer", bpe_mod);
        au_agent_mod.addImport("sampling", sampling_mod);
        au_agent_mod.addImport("state_store", state_store_mod);
        au_agent_mod.addImport("face_sync", face_sync_mod);
        const au_kg_mod = b.addModule("knowledge_graph", .{
            .root_source_file = b.path("src/knowledge_graph.zig"),
            .target = target,
            .optimize = optimize,
        });
        au_kg_mod.addImport("fixed_point", fixed_point_mod);
        const au_lat_mod = b.addModule("lattice", .{
            .root_source_file = b.path("src/lattice.zig"),
            .target = target,
            .optimize = optimize,
        });
        au_kg_mod.addImport("lattice", au_lat_mod);
        au_agent_mod.addImport("lattice", au_lat_mod);
        au_agent_mod.addImport("knowledge_graph", au_kg_mod);
        au_agent_mod.addImport("corpus_seed", corpus_seed_mod);
        const au_mem_mod = b.addModule("memory", .{
            .root_source_file = b.path("src/memory.zig"),
            .target = target,
            .optimize = optimize,
        });
        au_agent_mod.addImport("memory", au_mem_mod);
        const au_perc_mod = b.addModule("perception", .{
            .root_source_file = b.path("src/perception.zig"),
            .target = target,
            .optimize = optimize,
        });
        au_perc_mod.addImport("fixed_point", fixed_point_mod);
        au_agent_mod.addImport("perception", au_perc_mod);
        const au_metacog_mod = b.addModule("metacognition_engine", .{
            .root_source_file = b.path("src/metacognition_engine.zig"),
            .target = target,
            .optimize = optimize,
        });
        au_agent_mod.addImport("metacognition_engine", au_metacog_mod);
        const au_dyn_routes_mod = b.addModule("dynamic_routes", .{
            .root_source_file = b.path("src/dynamic_routes.zig"),
            .target = target,
            .optimize = optimize,
        });
        au_metacog_mod.addImport("dynamic_routes", au_dyn_routes_mod);
        au_metacog_mod.addImport("q128", q128_mod);
        au_agent_mod.addImport("dynamic_routes", au_dyn_routes_mod);
        const au_trivium_mod = b.addModule("trivium", .{
            .root_source_file = b.path("src/trivium.zig"),
            .target = target,
            .optimize = optimize,
        });
        au_agent_mod.addImport("trivium", au_trivium_mod);
        const au_quadrivium_mod = b.addModule("quadrivium", .{
            .root_source_file = b.path("src/quadrivium.zig"),
            .target = target,
            .optimize = optimize,
        });
        au_quadrivium_mod.addImport("fixed_point", fixed_point_mod);
        au_agent_mod.addImport("quadrivium", au_quadrivium_mod);
        const au_corpus_learner_mod = b.addModule("corpus_learner", .{
            .root_source_file = b.path("src/corpus_learner.zig"),
            .target = target,
            .optimize = optimize,
        });
        au_corpus_learner_mod.addImport("trivium", au_trivium_mod);
        au_corpus_learner_mod.addImport("quadrivium", au_quadrivium_mod);
        au_corpus_learner_mod.addImport("dynamic_routes", au_dyn_routes_mod);
        au_agent_mod.addImport("corpus_learner", au_corpus_learner_mod);
        const au_voice_codec_mod = b.addModule("voice_codec", .{
            .root_source_file = b.path("src/voice_codec.zig"),
            .target = target,
            .optimize = optimize,
        });
        au_voice_codec_mod.addImport("fixed_point", fixed_point_mod);
        au_agent_mod.addImport("voice_codec", au_voice_codec_mod);
        const au_vk_mod = b.addModule("vulkan_compute", .{
            .root_source_file = b.path("src/vulkan_compute.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        au_agent_mod.addImport("vulkan_compute", au_vk_mod);
        au_exe.root_module.addImport("agent", au_agent_mod);
        audit_step.dependOn(&b.addRunArtifact(au_exe).step);
    }

    // === Manual Integration Tests Step ===

    const manual_step = b.step("manual", "Run manual integration tests");
    {
        // manual_agent
        const ma_exe = b.addExecutable(.{
            .name = "manual_agent",
            .root_source_file = b.path("tests/manual_agent.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        ma_exe.root_module.addImport("fixed_point", fixed_point_mod);
        const ma_agent_mod = b.addModule("agent", .{
            .root_source_file = b.path("src/agent.zig"),
            .target = target,
            .optimize = optimize,
        });
        ma_agent_mod.addImport("fixed_point", fixed_point_mod);
        ma_agent_mod.addImport("q128", q128_mod);
        ma_agent_mod.addImport("bpe_tokenizer", bpe_mod);
        ma_agent_mod.addImport("sampling", sampling_mod);
        ma_agent_mod.addImport("state_store", state_store_mod);
        ma_agent_mod.addImport("face_sync", face_sync_mod);
        const ma_kg_mod = b.addModule("knowledge_graph", .{
            .root_source_file = b.path("src/knowledge_graph.zig"),
            .target = target,
            .optimize = optimize,
        });
        ma_kg_mod.addImport("fixed_point", fixed_point_mod);
        const ma_lat_mod = b.addModule("lattice", .{
            .root_source_file = b.path("src/lattice.zig"),
            .target = target,
            .optimize = optimize,
        });
        ma_kg_mod.addImport("lattice", ma_lat_mod);
        ma_agent_mod.addImport("lattice", ma_lat_mod);
        ma_agent_mod.addImport("knowledge_graph", ma_kg_mod);
        ma_agent_mod.addImport("corpus_seed", corpus_seed_mod);
        const ma_mem_mod = b.addModule("memory", .{
            .root_source_file = b.path("src/memory.zig"),
            .target = target,
            .optimize = optimize,
        });
        ma_agent_mod.addImport("memory", ma_mem_mod);
        const ma_perc_mod = b.addModule("perception", .{
            .root_source_file = b.path("src/perception.zig"),
            .target = target,
            .optimize = optimize,
        });
        ma_perc_mod.addImport("fixed_point", fixed_point_mod);
        ma_agent_mod.addImport("perception", ma_perc_mod);
        const ma_metacog_mod = b.addModule("metacognition_engine", .{
            .root_source_file = b.path("src/metacognition_engine.zig"),
            .target = target,
            .optimize = optimize,
        });
        ma_agent_mod.addImport("metacognition_engine", ma_metacog_mod);
        const ma_dyn_routes_mod = b.addModule("dynamic_routes", .{
            .root_source_file = b.path("src/dynamic_routes.zig"),
            .target = target,
            .optimize = optimize,
        });
        ma_metacog_mod.addImport("dynamic_routes", ma_dyn_routes_mod);
        ma_metacog_mod.addImport("q128", q128_mod);
        ma_agent_mod.addImport("dynamic_routes", ma_dyn_routes_mod);
        const ma_trivium_mod = b.addModule("trivium", .{
            .root_source_file = b.path("src/trivium.zig"),
            .target = target,
            .optimize = optimize,
        });
        ma_agent_mod.addImport("trivium", ma_trivium_mod);
        const ma_quadrivium_mod = b.addModule("quadrivium", .{
            .root_source_file = b.path("src/quadrivium.zig"),
            .target = target,
            .optimize = optimize,
        });
        ma_quadrivium_mod.addImport("fixed_point", fixed_point_mod);
        ma_agent_mod.addImport("quadrivium", ma_quadrivium_mod);
        const ma_corpus_learner_mod = b.addModule("corpus_learner", .{
            .root_source_file = b.path("src/corpus_learner.zig"),
            .target = target,
            .optimize = optimize,
        });
        ma_corpus_learner_mod.addImport("trivium", ma_trivium_mod);
        ma_corpus_learner_mod.addImport("quadrivium", ma_quadrivium_mod);
        ma_corpus_learner_mod.addImport("dynamic_routes", ma_dyn_routes_mod);
        ma_agent_mod.addImport("corpus_learner", ma_corpus_learner_mod);
        const ma_voice_codec_mod = b.addModule("voice_codec", .{
            .root_source_file = b.path("src/voice_codec.zig"),
            .target = target,
            .optimize = optimize,
        });
        ma_voice_codec_mod.addImport("fixed_point", fixed_point_mod);
        ma_agent_mod.addImport("voice_codec", ma_voice_codec_mod);
        const ma_vk_mod = b.addModule("vulkan_compute", .{
            .root_source_file = b.path("src/vulkan_compute.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        ma_agent_mod.addImport("vulkan_compute", ma_vk_mod);
        ma_exe.root_module.addImport("agent", ma_agent_mod);
        manual_step.dependOn(&b.addRunArtifact(ma_exe).step);

        // manual_s0_projection
        const ms0_exe = b.addExecutable(.{
            .name = "manual_s0_projection",
            .root_source_file = b.path("tests/manual_s0_projection.zig"),
            .target = target,
            .optimize = optimize,
        });
        //        ms0_exe.root_module.addImport("s0_projection", s0_projection_mod);
        manual_step.dependOn(&b.addRunArtifact(ms0_exe).step);

        // manual_s7_compression
        const ms7_exe = b.addExecutable(.{
            .name = "manual_s7_compression",
            .root_source_file = b.path("tests/manual_s7_compression.zig"),
            .target = target,
            .optimize = optimize,
        });
        //        ms7_exe.root_module.addImport("s7_compression", s7_compression_mod);
        manual_step.dependOn(&b.addRunArtifact(ms7_exe).step);

        // manual_vocab_scaling
        const mvs_exe = b.addExecutable(.{
            .name = "manual_vocab_scaling",
            .root_source_file = b.path("tests/manual_vocab_scaling.zig"),
            .target = target,
            .optimize = optimize,
        });
        //        mvs_exe.root_module.addImport("vocab_lattice_scaling", vocab_lattice_scaling_mod);
        manual_step.dependOn(&b.addRunArtifact(mvs_exe).step);
    }

    // === SAMC Validation Step ===

    const samc_step = b.step("samc", "Run SAMC validation tests");
    {
        const sc_exe = b.addExecutable(.{
            .name = "prototype_samc_test",
            .root_source_file = b.path("tests/prototype_samc_test.zig"),
            .target = target,
            .optimize = optimize,
        });
        //        sc_exe.root_module.addImport("samc_lattice", samc_lattice_mod);
        //        sc_exe.root_module.addImport("samc_agent", samc_agent_mod);
        sc_exe.root_module.addImport("sampling", sampling_mod);
        samc_step.dependOn(&b.addRunArtifact(sc_exe).step);
    }

    // === Tool Server Test Step ===

    const tool_test_step = b.step("tool-test", "Run tool calling and server integration tests");
    {
        const tt_exe = b.addExecutable(.{
            .name = "tool_server_test",
            .root_source_file = b.path("tests/tool_server_test.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        tt_exe.root_module.addImport("fixed_point", fixed_point_mod);
        tt_exe.root_module.addImport("tools", tools_mod);
        const tt_server_mod = b.addModule("server", .{
            .root_source_file = b.path("src/server.zig"),
            .target = target,
            .optimize = optimize,
        });
        tt_server_mod.addImport("agent", agent_mod);
        tt_server_mod.addImport("fixed_point", fixed_point_mod);
        tt_server_mod.addImport("tools", tools_mod);
        tt_server_mod.addImport("bpe_tokenizer", bpe_mod);
        tt_server_mod.addImport("knowledge_graph", kg_mod);
        tt_server_mod.addImport("external_db", external_db_mod);
        tt_server_mod.addImport("turing_test", turing_test_mod);
        tt_exe.root_module.addImport("server", tt_server_mod);
        tool_test_step.dependOn(&b.addRunArtifact(tt_exe).step);
    }

    // === Vision Integration Test Step ===

    const vision_test_step = b.step("vision-test", "Run vision pipeline integration tests");
    {
        const vt_exe = b.addExecutable(.{
            .name = "vision_test",
            .root_source_file = b.path("tests/vision_test.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        vt_exe.root_module.addImport("image", image_mod);
        vt_exe.root_module.addImport("face_detect", face_detect_mod);
        vt_exe.root_module.addImport("face_recognize", face_recognize_mod);
        vt_exe.root_module.addImport("face_track", face_track_mod);
        vt_exe.root_module.addImport("gaze_headpose", gaze_headpose_mod);
        vt_exe.root_module.addImport("face_attributes", face_attributes_mod);
        vt_exe.root_module.addImport("face_quality", face_quality_mod);
        vt_exe.root_module.addImport("anti_spoofing", anti_spoofing_mod);
        vt_exe.root_module.addImport("face_analyzer", face_analyzer_mod);
        vision_test_step.dependOn(&b.addRunArtifact(vt_exe).step);
    }

    // === Geoview Integration Test Step ===

    const geoview_test_step = b.step("geoview-test", "Run geoview integration tests");
    {
        const gt_exe = b.addExecutable(.{
            .name = "geoview_test",
            .root_source_file = b.path("tests/geoview_test.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        gt_exe.root_module.addImport("geo_math", geo_math_mod);
        gt_exe.root_module.addImport("feed_flights", feed_flights_mod);
        gt_exe.root_module.addImport("feed_vessels", feed_vessels_mod);
        gt_exe.root_module.addImport("feed_satellites", feed_satellites_mod);
        gt_exe.root_module.addImport("feed_earthquakes", feed_earthquakes_mod);
        gt_exe.root_module.addImport("feed_cctv", feed_cctv_mod);
        gt_exe.root_module.addImport("live_feeds", live_feeds_mod);
        gt_exe.root_module.addImport("globe_render", globe_render_mod);
        gt_exe.root_module.addImport("camera", camera_mod);
        gt_exe.root_module.addImport("hud", hud_mod);
        gt_exe.root_module.addImport("annotation", annotation_mod);
        gt_exe.root_module.addImport("scene_director", scene_director_mod);
        gt_exe.root_module.addImport("voice_command", voice_command_mod);
        geoview_test_step.dependOn(&b.addRunArtifact(gt_exe).step);
    }

    // === WASM Build Step ===

    const wasm_step = b.step("wasm", "Build WASM module for browser embedding");
    {
        const wasm_target = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .freestanding });
        const wasm_optimize: std.builtin.OptimizeMode = .ReleaseSmall;

        const wasm_fp = b.addModule("fixed_point", .{
            .root_source_file = b.path("src/fixed_point.zig"),
            .target = wasm_target,
            .optimize = wasm_optimize,
        });
        const wasm_lat = b.addModule("lattice", .{
            .root_source_file = b.path("src/lattice.zig"),
            .target = wasm_target,
            .optimize = wasm_optimize,
        });
        const wasm_bpe = b.addModule("bpe_tokenizer", .{
            .root_source_file = b.path("src/bpe_tokenizer.zig"),
            .target = wasm_target,
            .optimize = wasm_optimize,
        });
        const wasm_samp = b.addModule("sampling", .{
            .root_source_file = b.path("src/sampling.zig"),
            .target = wasm_target,
            .optimize = wasm_optimize,
        });
        const wasm_kg = b.addModule("knowledge_graph", .{
            .root_source_file = b.path("src/knowledge_graph.zig"),
            .target = wasm_target,
            .optimize = wasm_optimize,
        });
        wasm_kg.addImport("fixed_point", wasm_fp);
        wasm_kg.addImport("lattice", wasm_lat);
        const wasm_tools = b.addModule("tools", .{
            .root_source_file = b.path("src/tools.zig"),
            .target = wasm_target,
            .optimize = wasm_optimize,
        });
        wasm_tools.addImport("fixed_point", wasm_fp);
        wasm_tools.addImport("knowledge_graph", wasm_kg);
        const wasm_geo = b.addModule("geo_math", .{
            .root_source_file = b.path("src/geoview/geo_math.zig"),
            .target = wasm_target,
            .optimize = wasm_optimize,
        });
        wasm_tools.addImport("geo_math", wasm_geo);
        const wasm_db = b.addModule("external_db", .{
            .root_source_file = b.path("src/external_db.zig"),
            .target = wasm_target,
            .optimize = wasm_optimize,
        });
        wasm_db.addImport("knowledge_graph", wasm_kg);
        wasm_tools.addImport("external_db", wasm_db);

        const wasm_state_store = b.addModule("state_store", .{
            .root_source_file = b.path("src/state_store.zig"),
            .target = wasm_target,
            .optimize = wasm_optimize,
        });
        const wasm_face_sync = b.addModule("face_sync", .{
            .root_source_file = b.path("src/face_sync.zig"),
            .target = wasm_target,
            .optimize = wasm_optimize,
        });
        wasm_face_sync.addImport("fixed_point", wasm_fp);
        const wasm_mem = b.addModule("memory", .{
            .root_source_file = b.path("src/memory.zig"),
            .target = wasm_target,
            .optimize = wasm_optimize,
        });
        const wasm_perc = b.addModule("perception", .{
            .root_source_file = b.path("src/perception.zig"),
            .target = wasm_target,
            .optimize = wasm_optimize,
        });
        wasm_perc.addImport("fixed_point", wasm_fp);

        const wasm_agent = b.addModule("agent", .{
            .root_source_file = b.path("src/agent.zig"),
            .target = wasm_target,
            .optimize = wasm_optimize,
        });
        wasm_agent.addImport("fixed_point", wasm_fp);
        wasm_agent.addImport("bpe_tokenizer", wasm_bpe);
        wasm_agent.addImport("sampling", wasm_samp);
        wasm_agent.addImport("state_store", wasm_state_store);
        wasm_agent.addImport("face_sync", wasm_face_sync);
        wasm_agent.addImport("knowledge_graph", wasm_kg);
        wasm_agent.addImport("memory", wasm_mem);
        wasm_agent.addImport("perception", wasm_perc);
        const wasm_metacog = b.addModule("metacognition_engine", .{
            .root_source_file = b.path("src/metacognition_engine.zig"),
            .target = wasm_target,
            .optimize = wasm_optimize,
        });
        wasm_agent.addImport("metacognition_engine", wasm_metacog);
        const wasm_dyn_routes = b.addModule("dynamic_routes", .{
            .root_source_file = b.path("src/dynamic_routes.zig"),
            .target = wasm_target,
            .optimize = wasm_optimize,
        });
        wasm_metacog.addImport("dynamic_routes", wasm_dyn_routes);
        wasm_agent.addImport("dynamic_routes", wasm_dyn_routes);
        const wasm_trivium = b.addModule("trivium", .{
            .root_source_file = b.path("src/trivium.zig"),
            .target = wasm_target,
            .optimize = wasm_optimize,
        });
        wasm_agent.addImport("trivium", wasm_trivium);
        const wasm_quadrivium = b.addModule("quadrivium", .{
            .root_source_file = b.path("src/quadrivium.zig"),
            .target = wasm_target,
            .optimize = wasm_optimize,
        });
        wasm_quadrivium.addImport("fixed_point", wasm_fp);
        wasm_agent.addImport("quadrivium", wasm_quadrivium);
        const wasm_corpus_learner = b.addModule("corpus_learner", .{
            .root_source_file = b.path("src/corpus_learner.zig"),
            .target = wasm_target,
            .optimize = wasm_optimize,
        });
        wasm_corpus_learner.addImport("trivium", wasm_trivium);
        wasm_corpus_learner.addImport("quadrivium", wasm_quadrivium);
        wasm_corpus_learner.addImport("dynamic_routes", wasm_dyn_routes);
        wasm_agent.addImport("corpus_learner", wasm_corpus_learner);
        const wasm_voice_codec = b.addModule("voice_codec", .{
            .root_source_file = b.path("src/voice_codec.zig"),
            .target = wasm_target,
            .optimize = wasm_optimize,
        });
        wasm_voice_codec.addImport("fixed_point", wasm_fp);
        wasm_agent.addImport("voice_codec", wasm_voice_codec);
        const wasm_vk = b.addModule("vulkan_compute", .{
            .root_source_file = b.path("src/vulkan_compute.zig"),
            .target = wasm_target,
            .optimize = wasm_optimize,
        });
        wasm_agent.addImport("vulkan_compute", wasm_vk);
        wasm_agent.addImport("lattice", wasm_lat);

        const wasm_corpus_seed = b.addModule("corpus_seed", .{
            .root_source_file = b.path("src/corpus_seed.zig"),
            .target = wasm_target,
            .optimize = wasm_optimize,
        });
        wasm_agent.addImport("corpus_seed", wasm_corpus_seed);

        const wasm_exe = b.addExecutable(.{
            .name = "qstar_llm",
            .root_source_file = b.path("src/wasm_exports.zig"),
            .target = wasm_target,
            .optimize = wasm_optimize,
            .strip = true,
        });
        wasm_exe.root_module.addImport("fixed_point", wasm_fp);
        wasm_exe.root_module.addImport("bpe_tokenizer", wasm_bpe);
        wasm_exe.root_module.addImport("sampling", wasm_samp);
        wasm_exe.root_module.addImport("knowledge_graph", wasm_kg);
        wasm_exe.root_module.addImport("tools", wasm_tools);
        wasm_exe.root_module.addImport("external_db", wasm_db);
        wasm_exe.root_module.addImport("agent", wasm_agent);
        wasm_exe.root_module.addImport("lattice", wasm_lat);

        const wasm_fp_bridge = b.addModule("fp_bridge", .{
            .root_source_file = b.path("src/fp_bridge.zig"),
            .target = wasm_target,
            .optimize = wasm_optimize,
        });
        wasm_fp_bridge.addImport("fixed_point", wasm_fp);
        const wasm_fp32 = b.addModule("fixed_point32", .{
            .root_source_file = b.path("src/fixed_point32.zig"),
            .target = wasm_target,
            .optimize = wasm_optimize,
        });
        wasm_fp_bridge.addImport("fixed_point32", wasm_fp32);
        wasm_exe.root_module.addImport("fp_bridge", wasm_fp_bridge);

        const browser_options = b.addOptions();
        browser_options.addOption(bool, "esp32", false);
        browser_options.addOption(bool, "device_lite", false);
        wasm_exe.root_module.addOptions("build_options", browser_options);

        wasm_exe.link_gc_sections = true;
        wasm_exe.entry = .disabled;
        wasm_exe.root_module.export_symbol_names = &.{
            "qstar_init",
            "qstar_get_input_ptr",
            "qstar_ingest",
            "qstar_run",
            "qstar_decode",
            "qstar_generate_long_form",
            "qstar_output_len",
            "qstar_get_activation",
            "qstar_e0_count",
            "qstar_tool_execute",
            "qstar_get_e0_index",
            "qstar_get_e_value",
            "qstar_is_boundary",
            "qstar_fp_one",
            "qstar_fp_to_f64",
            "qstar_deinit",
            "qstar_reset",
            "qstar_version",
            "qstar_learn_from_text",
            "qstar_get_corpus_sentence_count",
            "qstar_save_corpus",
        };

        const install_wasm = b.addInstallArtifact(wasm_exe, .{
            .dest_dir = .{ .override = .{ .custom = "wasm" } },
            .dest_sub_path = "qstar_llm.wasm",
        });
        wasm_step.dependOn(&install_wasm.step);

        // ESP32 variant: fixed 48 KB heap + 4 KB I/O buffers.
        const esp32_options = b.addOptions();
        esp32_options.addOption(bool, "esp32", true);
        esp32_options.addOption(bool, "device_lite", false);

        const wasm_esp32_exe = b.addExecutable(.{
            .name = "qstar_llm_esp32",
            .root_source_file = b.path("src/wasm_exports.zig"),
            .target = wasm_target,
            .optimize = wasm_optimize,
            .strip = true,
        });
        wasm_esp32_exe.root_module.addOptions("build_options", esp32_options);
        wasm_esp32_exe.root_module.addImport("fixed_point", wasm_fp);
        wasm_esp32_exe.root_module.addImport("bpe_tokenizer", wasm_bpe);
        wasm_esp32_exe.root_module.addImport("sampling", wasm_samp);
        wasm_esp32_exe.root_module.addImport("knowledge_graph", wasm_kg);
        wasm_esp32_exe.root_module.addImport("tools", wasm_tools);
        wasm_esp32_exe.root_module.addImport("external_db", wasm_db);
        wasm_esp32_exe.root_module.addImport("agent", wasm_agent);
        wasm_esp32_exe.root_module.addImport("lattice", wasm_lat);
        wasm_esp32_exe.root_module.addImport("fp_bridge", wasm_fp_bridge);
        wasm_esp32_exe.link_gc_sections = true;
        wasm_esp32_exe.entry = .disabled;
        wasm_esp32_exe.stack_size = 4 * 1024;
        // ESP32 variant excludes qstar_tool_execute — drops the tools module's
        // static word lists (~100 KB) from the binary via gc-sections.
        wasm_esp32_exe.root_module.export_symbol_names = &.{
            "qstar_init",
            "qstar_get_input_ptr",
            "qstar_ingest",
            "qstar_run",
            "qstar_decode",
            "qstar_generate_long_form",
            "qstar_output_len",
            "qstar_get_activation",
            "qstar_e0_count",
            "qstar_get_e0_index",
            "qstar_get_e_value",
            "qstar_is_boundary",
            "qstar_fp_one",
            "qstar_fp_to_f64",
            "qstar_deinit",
            "qstar_reset",
            "qstar_version",
            "qstar_learn_from_text",
            "qstar_get_corpus_sentence_count",
            "qstar_save_corpus",
        };

        const install_wasm_esp32 = b.addInstallArtifact(wasm_esp32_exe, .{
            .dest_dir = .{ .override = .{ .custom = "wasm" } },
            .dest_sub_path = "qstar_llm_esp32.wasm",
        });
        wasm_step.dependOn(&install_wasm_esp32.step);

        // ── Device-lite variant (ESP32-PICO-D4, ~171 KB free heap) ──────────
        // Lite corpus (~8 KB) + 32 KB agent heap + 4 KB I/O buffers.
        // Target: binary ≤ 60 KB + 1 page (64 KB) linear memory ≈ 164 KB total.
        const lite_options = b.addOptions();
        lite_options.addOption(bool, "esp32", true);
        lite_options.addOption(bool, "device_lite", true);

        const wasm_corpus_seed_lite = b.addModule("corpus_seed", .{
            .root_source_file = b.path("src/corpus_seed_lite.zig"),
            .target = wasm_target,
            .optimize = wasm_optimize,
        });

        const wasm_agent_lite = b.addModule("agent", .{
            .root_source_file = b.path("src/agent_lite.zig"),
            .target = wasm_target,
            .optimize = wasm_optimize,
        });
        wasm_agent_lite.addImport("fixed_point", wasm_fp);
        wasm_agent_lite.addImport("corpus_seed", wasm_corpus_seed_lite);

        const wasm_esp32_lite_exe = b.addExecutable(.{
            .name = "qstar_llm_esp32_lite",
            .root_source_file = b.path("src/wasm_exports.zig"),
            .target = wasm_target,
            .optimize = wasm_optimize,
            .strip = true,
        });
        wasm_esp32_lite_exe.root_module.addOptions("build_options", lite_options);
        wasm_esp32_lite_exe.root_module.addImport("fixed_point", wasm_fp);
        wasm_esp32_lite_exe.root_module.addImport("agent", wasm_agent_lite);
        wasm_esp32_lite_exe.root_module.addImport("fp_bridge", wasm_fp_bridge);
        wasm_esp32_lite_exe.link_gc_sections = true;
        wasm_esp32_lite_exe.entry = .disabled;
        wasm_esp32_lite_exe.stack_size = 4 * 1024;
        // Device-lite exports: 14 firmware-wired functions.
        // Includes run/decode/learn/save/load corpus, reset, deinit.
        // Excludes tool_execute, lattice queries, activation probes, fp helpers.
        wasm_esp32_lite_exe.root_module.export_symbol_names = &.{
            "qstar_init",
            "qstar_get_input_ptr",
            "qstar_ingest",
            "qstar_run",
            "qstar_decode",
            "qstar_generate_long_form",
            "qstar_output_len",
            "qstar_version",
            "qstar_learn_from_text",
            "qstar_get_corpus_sentence_count",
            "qstar_save_corpus",
            "qstar_load_corpus",
            "qstar_reset",
            "qstar_deinit",
        };

        const install_wasm_esp32_lite = b.addInstallArtifact(wasm_esp32_lite_exe, .{
            .dest_dir = .{ .override = .{ .custom = "wasm" } },
            .dest_sub_path = "qstar_llm_esp32_lite.wasm",
        });
        wasm_step.dependOn(&install_wasm_esp32_lite.step);
    }

    // === HTML Build Step (embeds WASM + corpus into universe_template.html) ===

    // Corpus build step: qstar corpus build qstar_corpus.txt zig-out/qstar_corpus.qsc
    const corpus_step = b.step("corpus", "Build compressed .qsc corpus container from qstar_corpus.txt");
    {
        const run_corpus = b.addRunArtifact(cli_exe);
        run_corpus.addArg("corpus");
        run_corpus.addArg("build");
        run_corpus.addArg("qstar_corpus.txt");
        run_corpus.addArg("zig-out/qstar_corpus.qsc");
        run_corpus.addArg("--page-size");
        run_corpus.addArg("65536");
        corpus_step.dependOn(&run_corpus.step);
    }

    const html_step = b.step("html", "Build self-contained universe.html with embedded WASM + corpus");
    {
        // Build version: git short hash when available, else a timestamp.
        var git_code: u8 = 0;
        const git_hash = b.runAllowFail(&.{ "git", "rev-parse", "--short", "HEAD" }, &git_code, .Ignore) catch null;
        const version = if (git_hash) |h| b.fmt("git-{s}", .{std.mem.trim(u8, h, " \n\r")}) else b.fmt("0.0.0-{d}", .{std.time.timestamp()});

        const html_exe = b.addExecutable(.{
            .name = "build_html",
            .root_source_file = b.path("src/build_html.zig"),
            .target = target,
            .optimize = optimize,
        });
        html_exe.root_module.addImport("corpus_store", corpus_store_mod);
        html_exe.root_module.addImport("compress", compress_mod);

        const run_html = b.addRunArtifact(html_exe);
        // File args are tracked as inputs so the step re-runs when the
        // template / wasm / corpus change (plain addArg would cache-stale).
        run_html.addArg("--wasm");
        run_html.addFileArg(b.path("zig-out/wasm/qstar_llm.wasm"));
        run_html.addArg("--template");
        run_html.addFileArg(b.path("src/universe_template.html"));
        run_html.addArg("--output");
        run_html.addArg("zig-out/universe.html");
        run_html.addArg("--corpus");
        run_html.addFileArg(b.path("zig-out/qstar_corpus.qsc"));
        run_html.addArg("--distill");
        run_html.addArg("7000000"); // 7 MB raw -> ~9.3 MB base64 (<= 10 MB guard)
        run_html.addArg("--version");
        run_html.addArg(version);
        run_html.addArg("--seed");
        run_html.addFileArg(b.path("zig-out/seed/qstar_seed.bin"));

        html_step.dependOn(&run_html.step);
        html_step.dependOn(wasm_step);
        html_step.dependOn(corpus_step);
    }

    // === Benchmark Steps ===

    const competitive_bench_step = b.step("competitive-bench", "Run competitive benchmark suite: Qstar vs Ollama vs OpenAI vs Maple");
    const qstar_bench_step = b.step("qstar-bench", "Run Qstar-only standard benchmark with cross-judging");
    const maple_standard_bench_step = b.step("maple-standard-bench", "Run Maple-only standard benchmark with cross-judging");
    {
        const cb_exe = b.addExecutable(.{
            .name = "competitive_bench",
            .root_source_file = b.path("tests/competitive_bench.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        cb_exe.root_module.addImport("fixed_point", fixed_point_mod);

        // Agent module instance for competitive bench
        const cb_agent_mod = b.addModule("agent", .{
            .root_source_file = b.path("src/agent.zig"),
            .target = target,
            .optimize = optimize,
        });
        cb_agent_mod.addImport("fixed_point", fixed_point_mod);
        cb_agent_mod.addImport("bpe_tokenizer", bpe_mod);
        cb_agent_mod.addImport("sampling", sampling_mod);
        cb_agent_mod.addImport("state_store", state_store_mod);
        cb_agent_mod.addImport("face_sync", face_sync_mod);
        const cb_kg_mod = b.addModule("knowledge_graph", .{
            .root_source_file = b.path("src/knowledge_graph.zig"),
            .target = target,
            .optimize = optimize,
        });
        cb_kg_mod.addImport("fixed_point", fixed_point_mod);
        const cb_lat_mod = b.addModule("lattice", .{
            .root_source_file = b.path("src/lattice.zig"),
            .target = target,
            .optimize = optimize,
        });
        cb_kg_mod.addImport("lattice", cb_lat_mod);
        cb_agent_mod.addImport("lattice", cb_lat_mod);
        cb_agent_mod.addImport("knowledge_graph", cb_kg_mod);
        cb_agent_mod.addImport("corpus_seed", corpus_seed_mod);
        const cb_mem_mod = b.addModule("memory", .{
            .root_source_file = b.path("src/memory.zig"),
            .target = target,
            .optimize = optimize,
        });
        cb_agent_mod.addImport("memory", cb_mem_mod);
        const cb_perc_mod = b.addModule("perception", .{
            .root_source_file = b.path("src/perception.zig"),
            .target = target,
            .optimize = optimize,
        });
        cb_perc_mod.addImport("fixed_point", fixed_point_mod);
        cb_agent_mod.addImport("perception", cb_perc_mod);
        const cb_metacog_mod = b.addModule("metacognition_engine", .{
            .root_source_file = b.path("src/metacognition_engine.zig"),
            .target = target,
            .optimize = optimize,
        });
        cb_agent_mod.addImport("metacognition_engine", cb_metacog_mod);
        const cb_dyn_routes_mod = b.addModule("dynamic_routes", .{
            .root_source_file = b.path("src/dynamic_routes.zig"),
            .target = target,
            .optimize = optimize,
        });
        cb_metacog_mod.addImport("dynamic_routes", cb_dyn_routes_mod);
        cb_metacog_mod.addImport("q128", q128_mod);
        cb_agent_mod.addImport("dynamic_routes", cb_dyn_routes_mod);
        const cb_trivium_mod = b.addModule("trivium", .{
            .root_source_file = b.path("src/trivium.zig"),
            .target = target,
            .optimize = optimize,
        });
        cb_agent_mod.addImport("trivium", cb_trivium_mod);
        const cb_quadrivium_mod = b.addModule("quadrivium", .{
            .root_source_file = b.path("src/quadrivium.zig"),
            .target = target,
            .optimize = optimize,
        });
        cb_quadrivium_mod.addImport("fixed_point", fixed_point_mod);
        cb_agent_mod.addImport("quadrivium", cb_quadrivium_mod);
        const cb_corpus_learner_mod = b.addModule("corpus_learner", .{
            .root_source_file = b.path("src/corpus_learner.zig"),
            .target = target,
            .optimize = optimize,
        });
        cb_corpus_learner_mod.addImport("trivium", cb_trivium_mod);
        cb_corpus_learner_mod.addImport("quadrivium", cb_quadrivium_mod);
        cb_corpus_learner_mod.addImport("dynamic_routes", cb_dyn_routes_mod);
        cb_agent_mod.addImport("corpus_learner", cb_corpus_learner_mod);
        const cb_voice_codec_mod = b.addModule("voice_codec", .{
            .root_source_file = b.path("src/voice_codec.zig"),
            .target = target,
            .optimize = optimize,
        });
        cb_voice_codec_mod.addImport("fixed_point", fixed_point_mod);
        cb_agent_mod.addImport("voice_codec", cb_voice_codec_mod);
        const cb_vk_mod = b.addModule("vulkan_compute", .{
            .root_source_file = b.path("src/vulkan_compute.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        cb_agent_mod.addImport("vulkan_compute", cb_vk_mod);

        // Tools module for competitive bench agent
        const cb_tools_mod = b.addModule("tools", .{
            .root_source_file = b.path("src/tools.zig"),
            .target = target,
            .optimize = optimize,
        });
        cb_tools_mod.addImport("fixed_point", fixed_point_mod);
        cb_tools_mod.addImport("knowledge_graph", cb_kg_mod);
        const cb_ext_db_mod = b.addModule("external_db", .{
            .root_source_file = b.path("src/external_db.zig"),
            .target = target,
            .optimize = optimize,
        });
        cb_ext_db_mod.addImport("knowledge_graph", cb_kg_mod);
        cb_tools_mod.addImport("external_db", cb_ext_db_mod);
        const cb_geo_math_mod = b.addModule("geo_math", .{
            .root_source_file = b.path("src/geoview/geo_math.zig"),
            .target = target,
            .optimize = optimize,
        });
        cb_tools_mod.addImport("geo_math", cb_geo_math_mod);
        cb_agent_mod.addImport("tools", cb_tools_mod);

        cb_exe.root_module.addImport("agent", cb_agent_mod);

        // Ollama client
        const cb_ollama_mod = b.addModule("ollama_client", .{
            .root_source_file = b.path("src/ollama_client.zig"),
            .target = target,
            .optimize = optimize,
        });
        const cb_llm_provider_mod = b.addModule("llm_provider", .{
            .root_source_file = b.path("src/llm_provider.zig"),
            .target = target,
            .optimize = optimize,
        });
        cb_llm_provider_mod.addImport("ollama_client", cb_ollama_mod);
        cb_llm_provider_mod.addImport("openai_client", openai_mod);
        cb_llm_provider_mod.addImport("env_loader", env_loader_mod);
        cb_exe.root_module.addImport("ollama_client", cb_ollama_mod);
        cb_exe.root_module.addImport("openai_client", openai_mod);
        cb_exe.root_module.addImport("env_loader", env_loader_mod);
        cb_exe.root_module.addImport("llm_provider", cb_llm_provider_mod);
        cb_exe.root_module.addImport("maple_client", maple_client_mod);

        // BPE tokenizer (for runCompetitiveBenchmark)
        cb_exe.root_module.addImport("bpe_tokenizer", bpe_mod);

        // Training module (for loadCorpusFromFile)
        const cb_training_mod = b.addModule("training", .{
            .root_source_file = b.path("src/training.zig"),
            .target = target,
            .optimize = optimize,
        });
        cb_training_mod.addImport("agent", cb_agent_mod);
        cb_training_mod.addImport("ollama_client", cb_ollama_mod);
        cb_training_mod.addImport("openai_client", openai_mod);
        cb_training_mod.addImport("doc_loader", doc_loader_mod);
        cb_training_mod.addImport("corpus_store", corpus_store_mod);
        cb_training_mod.addImport("fixed_point", fixed_point_mod);

        // Prompt generator module (Ollama-based random prompt generation)
        const cb_prompt_gen_mod = b.addModule("prompt_generator", .{
            .root_source_file = b.path("src/prompt_generator.zig"),
            .target = target,
            .optimize = optimize,
        });
        cb_prompt_gen_mod.addImport("ollama_client", cb_ollama_mod);
        cb_training_mod.addImport("prompt_generator", cb_prompt_gen_mod);
        cb_exe.root_module.addImport("training", cb_training_mod);
        cb_exe.root_module.addImport("prompt_generator", cb_prompt_gen_mod);

        const cb_run = b.addRunArtifact(cb_exe);
        if (b.args) |args| {
            cb_run.addArgs(args);
        }
        competitive_bench_step.dependOn(&cb_run.step);

        // === Qstar Standard Benchmark Step ===

        const qb_run = b.addRunArtifact(cb_exe);
        qb_run.addArgs(&.{"--mode"});
        qb_run.addArgs(&.{"qstar"});
        if (b.args) |args| {
            qb_run.addArgs(args);
        }
        qstar_bench_step.dependOn(&qb_run.step);

        // === Maple Standard Benchmark Step ===

        const mb_run = b.addRunArtifact(cb_exe);
        mb_run.addArgs(&.{"--mode"});
        mb_run.addArgs(&.{"maple"});
        if (b.args) |args| {
            mb_run.addArgs(args);
        }
        maple_standard_bench_step.dependOn(&mb_run.step);
    }

    // === Meta Benchmark Step ===

    const meta_bench_step = b.step("meta-bench", "Run metacognitive benchmark: Ollama-generated prompts, Qstar vs OpenAI, remote Ollama judge, training feed");
    {
        const mb_exe = b.addExecutable(.{
            .name = "meta_bench",
            .root_source_file = b.path("tests/meta_bench.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        mb_exe.root_module.addImport("fixed_point", fixed_point_mod);

        // Agent module
        const mb_agent_mod = b.addModule("agent", .{
            .root_source_file = b.path("src/agent.zig"),
            .target = target,
            .optimize = optimize,
        });
        mb_agent_mod.addImport("fixed_point", fixed_point_mod);
        mb_agent_mod.addImport("bpe_tokenizer", bpe_mod);
        mb_agent_mod.addImport("sampling", sampling_mod);
        mb_agent_mod.addImport("state_store", state_store_mod);
        mb_agent_mod.addImport("face_sync", face_sync_mod);

        const mb_kg_mod = b.addModule("knowledge_graph", .{
            .root_source_file = b.path("src/knowledge_graph.zig"),
            .target = target,
            .optimize = optimize,
        });
        mb_kg_mod.addImport("fixed_point", fixed_point_mod);
        const mb_lat_mod = b.addModule("lattice", .{
            .root_source_file = b.path("src/lattice.zig"),
            .target = target,
            .optimize = optimize,
        });
        mb_kg_mod.addImport("lattice", mb_lat_mod);
        mb_agent_mod.addImport("lattice", mb_lat_mod);
        mb_agent_mod.addImport("knowledge_graph", mb_kg_mod);
        mb_agent_mod.addImport("corpus_seed", corpus_seed_mod);

        const mb_mem_mod = b.addModule("memory", .{
            .root_source_file = b.path("src/memory.zig"),
            .target = target,
            .optimize = optimize,
        });
        mb_agent_mod.addImport("memory", mb_mem_mod);

        const mb_perc_mod = b.addModule("perception", .{
            .root_source_file = b.path("src/perception.zig"),
            .target = target,
            .optimize = optimize,
        });
        mb_perc_mod.addImport("fixed_point", fixed_point_mod);
        mb_agent_mod.addImport("perception", mb_perc_mod);

        const mb_metacog_mod = b.addModule("metacognition_engine", .{
            .root_source_file = b.path("src/metacognition_engine.zig"),
            .target = target,
            .optimize = optimize,
        });
        mb_agent_mod.addImport("metacognition_engine", mb_metacog_mod);

        const mb_dyn_routes_mod = b.addModule("dynamic_routes", .{
            .root_source_file = b.path("src/dynamic_routes.zig"),
            .target = target,
            .optimize = optimize,
        });
        mb_metacog_mod.addImport("dynamic_routes", mb_dyn_routes_mod);
        mb_metacog_mod.addImport("q128", q128_mod);
        mb_agent_mod.addImport("dynamic_routes", mb_dyn_routes_mod);

        const mb_trivium_mod = b.addModule("trivium", .{
            .root_source_file = b.path("src/trivium.zig"),
            .target = target,
            .optimize = optimize,
        });
        mb_agent_mod.addImport("trivium", mb_trivium_mod);

        const mb_quadrivium_mod = b.addModule("quadrivium", .{
            .root_source_file = b.path("src/quadrivium.zig"),
            .target = target,
            .optimize = optimize,
        });
        mb_quadrivium_mod.addImport("fixed_point", fixed_point_mod);
        mb_agent_mod.addImport("quadrivium", mb_quadrivium_mod);
        const mb_corpus_learner_mod = b.addModule("corpus_learner", .{
            .root_source_file = b.path("src/corpus_learner.zig"),
            .target = target,
            .optimize = optimize,
        });
        mb_corpus_learner_mod.addImport("trivium", mb_trivium_mod);
        mb_corpus_learner_mod.addImport("quadrivium", mb_quadrivium_mod);
        mb_corpus_learner_mod.addImport("dynamic_routes", mb_dyn_routes_mod);
        mb_agent_mod.addImport("corpus_learner", mb_corpus_learner_mod);

        const mb_voice_codec_mod = b.addModule("voice_codec", .{
            .root_source_file = b.path("src/voice_codec.zig"),
            .target = target,
            .optimize = optimize,
        });
        mb_voice_codec_mod.addImport("fixed_point", fixed_point_mod);
        mb_agent_mod.addImport("voice_codec", mb_voice_codec_mod);

        const mb_vk_mod = b.addModule("vulkan_compute", .{
            .root_source_file = b.path("src/vulkan_compute.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        mb_agent_mod.addImport("vulkan_compute", mb_vk_mod);

        // Tools
        const mb_tools_mod = b.addModule("tools", .{
            .root_source_file = b.path("src/tools.zig"),
            .target = target,
            .optimize = optimize,
        });
        mb_tools_mod.addImport("fixed_point", fixed_point_mod);
        mb_tools_mod.addImport("knowledge_graph", mb_kg_mod);
        const mb_ext_db_mod = b.addModule("external_db", .{
            .root_source_file = b.path("src/external_db.zig"),
            .target = target,
            .optimize = optimize,
        });
        mb_ext_db_mod.addImport("knowledge_graph", mb_kg_mod);
        mb_tools_mod.addImport("external_db", mb_ext_db_mod);
        const mb_geo_math_mod = b.addModule("geo_math", .{
            .root_source_file = b.path("src/geoview/geo_math.zig"),
            .target = target,
            .optimize = optimize,
        });
        mb_tools_mod.addImport("geo_math", mb_geo_math_mod);
        mb_agent_mod.addImport("tools", mb_tools_mod);

        mb_exe.root_module.addImport("agent", mb_agent_mod);

        // Ollama client
        const mb_ollama_mod = b.addModule("ollama_client", .{
            .root_source_file = b.path("src/ollama_client.zig"),
            .target = target,
            .optimize = optimize,
        });
        mb_exe.root_module.addImport("ollama_client", mb_ollama_mod);
        mb_exe.root_module.addImport("openai_client", openai_mod);
        mb_exe.root_module.addImport("env_loader", env_loader_mod);
        mb_exe.root_module.addImport("bpe_tokenizer", bpe_mod);

        // Training module
        const mb_training_mod = b.addModule("training", .{
            .root_source_file = b.path("src/training.zig"),
            .target = target,
            .optimize = optimize,
        });
        mb_training_mod.addImport("agent", mb_agent_mod);
        mb_training_mod.addImport("ollama_client", mb_ollama_mod);
        mb_training_mod.addImport("openai_client", openai_mod);
        mb_training_mod.addImport("doc_loader", doc_loader_mod);
        mb_training_mod.addImport("corpus_store", corpus_store_mod);
        mb_training_mod.addImport("fixed_point", fixed_point_mod);
        mb_training_mod.addImport("dynamic_routes", mb_dyn_routes_mod);
        mb_training_mod.addImport("metacognition_engine", mb_metacog_mod);

        // Prompt generator
        const mb_prompt_gen_mod = b.addModule("prompt_generator", .{
            .root_source_file = b.path("src/prompt_generator.zig"),
            .target = target,
            .optimize = optimize,
        });
        mb_prompt_gen_mod.addImport("ollama_client", mb_ollama_mod);
        mb_training_mod.addImport("prompt_generator", mb_prompt_gen_mod);
        mb_exe.root_module.addImport("training", mb_training_mod);
        mb_exe.root_module.addImport("prompt_generator", mb_prompt_gen_mod);

        const mb_run = b.addRunArtifact(mb_exe);
        if (b.args) |args| {
            mb_run.addArgs(args);
        }
        meta_bench_step.dependOn(&mb_run.step);
    }

    // === Semantic Training Step ===

    const semantic_train_step = b.step("semantic-train", "Run semantic training: OpenAI generates prompts + teacher responses, Qstar learns via corpus + KG + dynamic routes");
    {
        const st_exe = b.addExecutable(.{
            .name = "semantic_train",
            .root_source_file = b.path("tests/semantic_train.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        st_exe.root_module.addImport("fixed_point", fixed_point_mod);

        // Agent module
        const st_agent_mod = b.addModule("agent", .{
            .root_source_file = b.path("src/agent.zig"),
            .target = target,
            .optimize = optimize,
        });
        st_agent_mod.addImport("fixed_point", fixed_point_mod);
        st_agent_mod.addImport("bpe_tokenizer", bpe_mod);
        st_agent_mod.addImport("sampling", sampling_mod);
        st_agent_mod.addImport("state_store", state_store_mod);
        st_agent_mod.addImport("face_sync", face_sync_mod);

        const st_kg_mod = b.addModule("knowledge_graph", .{
            .root_source_file = b.path("src/knowledge_graph.zig"),
            .target = target,
            .optimize = optimize,
        });
        st_kg_mod.addImport("fixed_point", fixed_point_mod);
        const st_lat_mod = b.addModule("lattice", .{
            .root_source_file = b.path("src/lattice.zig"),
            .target = target,
            .optimize = optimize,
        });
        st_kg_mod.addImport("lattice", st_lat_mod);
        st_agent_mod.addImport("lattice", st_lat_mod);
        st_agent_mod.addImport("knowledge_graph", st_kg_mod);
        st_agent_mod.addImport("corpus_seed", corpus_seed_mod);

        const st_mem_mod = b.addModule("memory", .{
            .root_source_file = b.path("src/memory.zig"),
            .target = target,
            .optimize = optimize,
        });
        st_agent_mod.addImport("memory", st_mem_mod);

        const st_perc_mod = b.addModule("perception", .{
            .root_source_file = b.path("src/perception.zig"),
            .target = target,
            .optimize = optimize,
        });
        st_perc_mod.addImport("fixed_point", fixed_point_mod);
        st_agent_mod.addImport("perception", st_perc_mod);

        const st_metacog_mod = b.addModule("metacognition_engine", .{
            .root_source_file = b.path("src/metacognition_engine.zig"),
            .target = target,
            .optimize = optimize,
        });
        st_agent_mod.addImport("metacognition_engine", st_metacog_mod);

        const st_dyn_routes_mod = b.addModule("dynamic_routes", .{
            .root_source_file = b.path("src/dynamic_routes.zig"),
            .target = target,
            .optimize = optimize,
        });
        st_metacog_mod.addImport("dynamic_routes", st_dyn_routes_mod);
        st_metacog_mod.addImport("q128", q128_mod);
        st_agent_mod.addImport("dynamic_routes", st_dyn_routes_mod);

        const st_trivium_mod = b.addModule("trivium", .{
            .root_source_file = b.path("src/trivium.zig"),
            .target = target,
            .optimize = optimize,
        });
        st_agent_mod.addImport("trivium", st_trivium_mod);

        const st_quadrivium_mod = b.addModule("quadrivium", .{
            .root_source_file = b.path("src/quadrivium.zig"),
            .target = target,
            .optimize = optimize,
        });
        st_quadrivium_mod.addImport("fixed_point", fixed_point_mod);
        st_agent_mod.addImport("quadrivium", st_quadrivium_mod);
        const st_corpus_learner_mod = b.addModule("corpus_learner", .{
            .root_source_file = b.path("src/corpus_learner.zig"),
            .target = target,
            .optimize = optimize,
        });
        st_corpus_learner_mod.addImport("trivium", st_trivium_mod);
        st_corpus_learner_mod.addImport("quadrivium", st_quadrivium_mod);
        st_corpus_learner_mod.addImport("dynamic_routes", st_dyn_routes_mod);
        st_agent_mod.addImport("corpus_learner", st_corpus_learner_mod);

        const st_voice_codec_mod = b.addModule("voice_codec", .{
            .root_source_file = b.path("src/voice_codec.zig"),
            .target = target,
            .optimize = optimize,
        });
        st_voice_codec_mod.addImport("fixed_point", fixed_point_mod);
        st_agent_mod.addImport("voice_codec", st_voice_codec_mod);

        const st_vk_mod = b.addModule("vulkan_compute", .{
            .root_source_file = b.path("src/vulkan_compute.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        st_agent_mod.addImport("vulkan_compute", st_vk_mod);

        // Tools
        const st_tools_mod = b.addModule("tools", .{
            .root_source_file = b.path("src/tools.zig"),
            .target = target,
            .optimize = optimize,
        });
        st_tools_mod.addImport("fixed_point", fixed_point_mod);
        st_tools_mod.addImport("knowledge_graph", st_kg_mod);
        const st_ext_db_mod = b.addModule("external_db", .{
            .root_source_file = b.path("src/external_db.zig"),
            .target = target,
            .optimize = optimize,
        });
        st_ext_db_mod.addImport("knowledge_graph", st_kg_mod);
        st_tools_mod.addImport("external_db", st_ext_db_mod);
        const st_geo_math_mod = b.addModule("geo_math", .{
            .root_source_file = b.path("src/geoview/geo_math.zig"),
            .target = target,
            .optimize = optimize,
        });
        st_tools_mod.addImport("geo_math", st_geo_math_mod);
        st_agent_mod.addImport("tools", st_tools_mod);

        st_exe.root_module.addImport("agent", st_agent_mod);

        // Ollama client
        const st_ollama_mod = b.addModule("ollama_client", .{
            .root_source_file = b.path("src/ollama_client.zig"),
            .target = target,
            .optimize = optimize,
        });
        st_exe.root_module.addImport("ollama_client", st_ollama_mod);
        st_exe.root_module.addImport("openai_client", openai_mod);
        st_exe.root_module.addImport("env_loader", env_loader_mod);
        st_exe.root_module.addImport("bpe_tokenizer", bpe_mod);

        // Training module
        const st_training_mod = b.addModule("training", .{
            .root_source_file = b.path("src/training.zig"),
            .target = target,
            .optimize = optimize,
        });
        st_training_mod.addImport("agent", st_agent_mod);
        st_training_mod.addImport("ollama_client", st_ollama_mod);
        st_training_mod.addImport("openai_client", openai_mod);
        st_training_mod.addImport("doc_loader", doc_loader_mod);
        st_training_mod.addImport("corpus_store", corpus_store_mod);
        st_training_mod.addImport("fixed_point", fixed_point_mod);
        st_training_mod.addImport("dynamic_routes", st_dyn_routes_mod);
        st_training_mod.addImport("metacognition_engine", st_metacog_mod);
        st_exe.root_module.addImport("training", st_training_mod);

        const st_run = b.addRunArtifact(st_exe);
        if (b.args) |args| {
            st_run.addArgs(args);
        }
        semantic_train_step.dependOn(&st_run.step);
    }

    // === Competitive Training Step ===

    const competitive_train_step = b.step("competitive-train", "Run competitive training: 5-phase pipeline (curriculum, distillation, self-improvement, consolidation, adversarial)");
    {
        const ct_exe = b.addExecutable(.{
            .name = "competitive_train",
            .root_source_file = b.path("tests/competitive_train.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        ct_exe.root_module.addImport("fixed_point", fixed_point_mod);

        // Agent module
        const ct_agent_mod = b.addModule("agent", .{
            .root_source_file = b.path("src/agent.zig"),
            .target = target,
            .optimize = optimize,
        });
        ct_agent_mod.addImport("fixed_point", fixed_point_mod);
        ct_agent_mod.addImport("bpe_tokenizer", bpe_mod);
        ct_agent_mod.addImport("sampling", sampling_mod);
        ct_agent_mod.addImport("state_store", state_store_mod);
        ct_agent_mod.addImport("face_sync", face_sync_mod);

        const ct_kg_mod = b.addModule("knowledge_graph", .{
            .root_source_file = b.path("src/knowledge_graph.zig"),
            .target = target,
            .optimize = optimize,
        });
        ct_kg_mod.addImport("fixed_point", fixed_point_mod);
        const ct_lat_mod = b.addModule("lattice", .{
            .root_source_file = b.path("src/lattice.zig"),
            .target = target,
            .optimize = optimize,
        });
        ct_kg_mod.addImport("lattice", ct_lat_mod);
        ct_agent_mod.addImport("lattice", ct_lat_mod);
        ct_agent_mod.addImport("knowledge_graph", ct_kg_mod);
        ct_agent_mod.addImport("corpus_seed", corpus_seed_mod);

        const ct_mem_mod = b.addModule("memory", .{
            .root_source_file = b.path("src/memory.zig"),
            .target = target,
            .optimize = optimize,
        });
        ct_agent_mod.addImport("memory", ct_mem_mod);

        const ct_perc_mod = b.addModule("perception", .{
            .root_source_file = b.path("src/perception.zig"),
            .target = target,
            .optimize = optimize,
        });
        ct_perc_mod.addImport("fixed_point", fixed_point_mod);
        ct_agent_mod.addImport("perception", ct_perc_mod);

        const ct_metacog_mod = b.addModule("metacognition_engine", .{
            .root_source_file = b.path("src/metacognition_engine.zig"),
            .target = target,
            .optimize = optimize,
        });
        ct_agent_mod.addImport("metacognition_engine", ct_metacog_mod);

        const ct_dyn_routes_mod = b.addModule("dynamic_routes", .{
            .root_source_file = b.path("src/dynamic_routes.zig"),
            .target = target,
            .optimize = optimize,
        });
        ct_metacog_mod.addImport("dynamic_routes", ct_dyn_routes_mod);
        ct_metacog_mod.addImport("q128", q128_mod);
        ct_agent_mod.addImport("dynamic_routes", ct_dyn_routes_mod);

        const ct_trivium_mod = b.addModule("trivium", .{
            .root_source_file = b.path("src/trivium.zig"),
            .target = target,
            .optimize = optimize,
        });
        ct_agent_mod.addImport("trivium", ct_trivium_mod);

        const ct_quadrivium_mod = b.addModule("quadrivium", .{
            .root_source_file = b.path("src/quadrivium.zig"),
            .target = target,
            .optimize = optimize,
        });
        ct_quadrivium_mod.addImport("fixed_point", fixed_point_mod);
        ct_agent_mod.addImport("quadrivium", ct_quadrivium_mod);
        const ct_corpus_learner_mod = b.addModule("corpus_learner", .{
            .root_source_file = b.path("src/corpus_learner.zig"),
            .target = target,
            .optimize = optimize,
        });
        ct_corpus_learner_mod.addImport("trivium", ct_trivium_mod);
        ct_corpus_learner_mod.addImport("quadrivium", ct_quadrivium_mod);
        ct_corpus_learner_mod.addImport("dynamic_routes", ct_dyn_routes_mod);
        ct_agent_mod.addImport("corpus_learner", ct_corpus_learner_mod);

        const ct_voice_codec_mod = b.addModule("voice_codec", .{
            .root_source_file = b.path("src/voice_codec.zig"),
            .target = target,
            .optimize = optimize,
        });
        ct_voice_codec_mod.addImport("fixed_point", fixed_point_mod);
        ct_agent_mod.addImport("voice_codec", ct_voice_codec_mod);

        const ct_vk_mod = b.addModule("vulkan_compute", .{
            .root_source_file = b.path("src/vulkan_compute.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        ct_agent_mod.addImport("vulkan_compute", ct_vk_mod);

        // Tools
        const ct_tools_mod = b.addModule("tools", .{
            .root_source_file = b.path("src/tools.zig"),
            .target = target,
            .optimize = optimize,
        });
        ct_tools_mod.addImport("fixed_point", fixed_point_mod);
        ct_tools_mod.addImport("knowledge_graph", ct_kg_mod);
        const ct_ext_db_mod = b.addModule("external_db", .{
            .root_source_file = b.path("src/external_db.zig"),
            .target = target,
            .optimize = optimize,
        });
        ct_ext_db_mod.addImport("knowledge_graph", ct_kg_mod);
        ct_tools_mod.addImport("external_db", ct_ext_db_mod);
        const ct_geo_math_mod = b.addModule("geo_math", .{
            .root_source_file = b.path("src/geoview/geo_math.zig"),
            .target = target,
            .optimize = optimize,
        });
        ct_tools_mod.addImport("geo_math", ct_geo_math_mod);
        ct_agent_mod.addImport("tools", ct_tools_mod);

        ct_exe.root_module.addImport("agent", ct_agent_mod);

        // Ollama client
        const ct_ollama_mod = b.addModule("ollama_client", .{
            .root_source_file = b.path("src/ollama_client.zig"),
            .target = target,
            .optimize = optimize,
        });
        ct_exe.root_module.addImport("ollama_client", ct_ollama_mod);
        ct_exe.root_module.addImport("openai_client", openai_mod);
        ct_exe.root_module.addImport("env_loader", env_loader_mod);
        ct_exe.root_module.addImport("bpe_tokenizer", bpe_mod);

        // Training module
        const ct_training_mod = b.addModule("training", .{
            .root_source_file = b.path("src/training.zig"),
            .target = target,
            .optimize = optimize,
        });
        ct_training_mod.addImport("agent", ct_agent_mod);
        ct_training_mod.addImport("ollama_client", ct_ollama_mod);
        ct_training_mod.addImport("openai_client", openai_mod);
        ct_training_mod.addImport("doc_loader", doc_loader_mod);
        ct_training_mod.addImport("corpus_store", corpus_store_mod);
        ct_training_mod.addImport("fixed_point", fixed_point_mod);
        ct_training_mod.addImport("dynamic_routes", ct_dyn_routes_mod);
        ct_training_mod.addImport("metacognition_engine", ct_metacog_mod);
        ct_exe.root_module.addImport("training", ct_training_mod);

        const ct_run = b.addRunArtifact(ct_exe);
        if (b.args) |args| {
            ct_run.addArgs(args);
        }
        competitive_train_step.dependOn(&ct_run.step);
    }

    // === Training Heartbeat Step ===

    const training_heartbeat_step = b.step("training-heartbeat", "Run training heartbeat: learn from JSON sources, compress corpus, push to Maple");
    {
        const hb_exe = b.addExecutable(.{
            .name = "training_heartbeat",
            .root_source_file = b.path("tests/training_heartbeat.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        hb_exe.root_module.addImport("fixed_point", fixed_point_mod);

        const hb_agent_mod = b.addModule("agent", .{
            .root_source_file = b.path("src/agent.zig"),
            .target = target,
            .optimize = optimize,
        });
        hb_agent_mod.addImport("fixed_point", fixed_point_mod);
        hb_agent_mod.addImport("bpe_tokenizer", bpe_mod);
        hb_agent_mod.addImport("sampling", sampling_mod);
        hb_agent_mod.addImport("state_store", state_store_mod);
        hb_agent_mod.addImport("face_sync", face_sync_mod);
        const hb_kg_mod = b.addModule("knowledge_graph", .{
            .root_source_file = b.path("src/knowledge_graph.zig"),
            .target = target,
            .optimize = optimize,
        });
        hb_kg_mod.addImport("fixed_point", fixed_point_mod);
        const hb_lat_mod = b.addModule("lattice", .{
            .root_source_file = b.path("src/lattice.zig"),
            .target = target,
            .optimize = optimize,
        });
        hb_kg_mod.addImport("lattice", hb_lat_mod);
        hb_agent_mod.addImport("lattice", hb_lat_mod);
        hb_agent_mod.addImport("knowledge_graph", hb_kg_mod);
        hb_agent_mod.addImport("corpus_seed", corpus_seed_mod);
        const hb_mem_mod = b.addModule("memory", .{
            .root_source_file = b.path("src/memory.zig"),
            .target = target,
            .optimize = optimize,
        });
        hb_agent_mod.addImport("memory", hb_mem_mod);
        const hb_perc_mod = b.addModule("perception", .{
            .root_source_file = b.path("src/perception.zig"),
            .target = target,
            .optimize = optimize,
        });
        hb_perc_mod.addImport("fixed_point", fixed_point_mod);
        hb_agent_mod.addImport("perception", hb_perc_mod);
        const hb_metacog_mod = b.addModule("metacognition_engine", .{
            .root_source_file = b.path("src/metacognition_engine.zig"),
            .target = target,
            .optimize = optimize,
        });
        hb_agent_mod.addImport("metacognition_engine", hb_metacog_mod);
        const hb_dyn_routes_mod = b.addModule("dynamic_routes", .{
            .root_source_file = b.path("src/dynamic_routes.zig"),
            .target = target,
            .optimize = optimize,
        });
        hb_metacog_mod.addImport("dynamic_routes", hb_dyn_routes_mod);
        hb_metacog_mod.addImport("q128", q128_mod);
        hb_agent_mod.addImport("dynamic_routes", hb_dyn_routes_mod);
        const hb_trivium_mod = b.addModule("trivium", .{
            .root_source_file = b.path("src/trivium.zig"),
            .target = target,
            .optimize = optimize,
        });
        hb_agent_mod.addImport("trivium", hb_trivium_mod);
        const hb_quadrivium_mod = b.addModule("quadrivium", .{
            .root_source_file = b.path("src/quadrivium.zig"),
            .target = target,
            .optimize = optimize,
        });
        hb_quadrivium_mod.addImport("fixed_point", fixed_point_mod);
        hb_agent_mod.addImport("quadrivium", hb_quadrivium_mod);
        const hb_corpus_learner_mod = b.addModule("corpus_learner", .{
            .root_source_file = b.path("src/corpus_learner.zig"),
            .target = target,
            .optimize = optimize,
        });
        hb_corpus_learner_mod.addImport("trivium", hb_trivium_mod);
        hb_corpus_learner_mod.addImport("quadrivium", hb_quadrivium_mod);
        hb_corpus_learner_mod.addImport("dynamic_routes", hb_dyn_routes_mod);
        hb_agent_mod.addImport("corpus_learner", hb_corpus_learner_mod);
        const hb_voice_codec_mod = b.addModule("voice_codec", .{
            .root_source_file = b.path("src/voice_codec.zig"),
            .target = target,
            .optimize = optimize,
        });
        hb_voice_codec_mod.addImport("fixed_point", fixed_point_mod);
        hb_agent_mod.addImport("voice_codec", hb_voice_codec_mod);
        const hb_vk_mod = b.addModule("vulkan_compute", .{
            .root_source_file = b.path("src/vulkan_compute.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        hb_agent_mod.addImport("vulkan_compute", hb_vk_mod);
        hb_exe.root_module.addImport("agent", hb_agent_mod);

        const hb_ollama_mod = b.addModule("ollama_client", .{
            .root_source_file = b.path("src/ollama_client.zig"),
            .target = target,
            .optimize = optimize,
        });
        const hb_llm_provider_mod = b.addModule("llm_provider", .{
            .root_source_file = b.path("src/llm_provider.zig"),
            .target = target,
            .optimize = optimize,
        });
        hb_llm_provider_mod.addImport("ollama_client", hb_ollama_mod);
        hb_llm_provider_mod.addImport("openai_client", openai_mod);
        hb_llm_provider_mod.addImport("env_loader", env_loader_mod);
        const hb_prompt_gen_mod = b.addModule("prompt_generator", .{
            .root_source_file = b.path("src/prompt_generator.zig"),
            .target = target,
            .optimize = optimize,
        });
        hb_prompt_gen_mod.addImport("ollama_client", hb_ollama_mod);
        const hb_training_mod = b.addModule("training", .{
            .root_source_file = b.path("src/training.zig"),
            .target = target,
            .optimize = optimize,
        });
        hb_training_mod.addImport("agent", hb_agent_mod);
        hb_training_mod.addImport("ollama_client", hb_ollama_mod);
        hb_training_mod.addImport("openai_client", openai_mod);
        hb_training_mod.addImport("corpus_store", corpus_store_mod);
        hb_training_mod.addImport("doc_loader", doc_loader_mod);
        hb_training_mod.addImport("fixed_point", fixed_point_mod);
        hb_training_mod.addImport("prompt_generator", hb_prompt_gen_mod);
        hb_exe.root_module.addImport("training", hb_training_mod);

        hb_exe.root_module.addImport("compress", compress_mod);
        hb_exe.root_module.addImport("corpus_store", corpus_store_mod);
        hb_exe.root_module.addImport("maple_client", maple_client_mod);
        hb_exe.root_module.addImport("env_loader", env_loader_mod);
        hb_exe.root_module.addImport("llm_provider", hb_llm_provider_mod);

        const hb_heartbeat_mod = b.addModule("heartbeat", .{
            .root_source_file = b.path("src/heartbeat.zig"),
            .target = target,
            .optimize = optimize,
        });
        hb_heartbeat_mod.addImport("agent", hb_agent_mod);
        hb_heartbeat_mod.addImport("training", hb_training_mod);
        hb_heartbeat_mod.addImport("compress", compress_mod);
        hb_heartbeat_mod.addImport("corpus_store", corpus_store_mod);
        hb_heartbeat_mod.addImport("maple_client", maple_client_mod);
        hb_heartbeat_mod.addImport("env_loader", env_loader_mod);
        hb_heartbeat_mod.addImport("fixed_point", fixed_point_mod);
        hb_heartbeat_mod.addImport("ollama_client", hb_ollama_mod);
        hb_heartbeat_mod.addImport("prompt_generator", hb_prompt_gen_mod);
        hb_heartbeat_mod.addImport("dynamic_routes", hb_dyn_routes_mod);
        hb_exe.root_module.addImport("heartbeat", hb_heartbeat_mod);

        const hb_run = b.addRunArtifact(hb_exe);
        if (b.args) |args| {
            hb_run.addArgs(args);
        }
        training_heartbeat_step.dependOn(&hb_run.step);
    }

    // === Vulkan Benchmark Step ===

    const vulkan_bench_step = b.step("vulkan-bench", "Benchmark CPU vs GPU inference cycles (requires Vulkan)");
    {
        const vb_exe = b.addExecutable(.{
            .name = "vulkan_benchmark",
            .root_source_file = b.path("tests/vulkan_benchmark.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        vb_exe.root_module.addImport("agent", agent_mod);
        vb_exe.root_module.addImport("fixed_point", fixed_point_mod);
        vb_exe.root_module.addImport("vulkan_compute", vulkan_compute_mod);

        const vb_run = b.addRunArtifact(vb_exe);
        if (b.args) |args| {
            vb_run.addArgs(args);
        }
        vulkan_bench_step.dependOn(&vb_run.step);
    }

    // === Full Regression Harness Step ===

    const regression_step = b.step("regression", "Run full regression harness (all 12 checks)");
    {
        const fr_exe = b.addExecutable(.{
            .name = "full_regression",
            .root_source_file = b.path("tests/full_regression.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        fr_exe.root_module.addImport("agent", cli_mod);
        fr_exe.root_module.addImport("fixed_point", fixed_point_mod);
        fr_exe.root_module.addImport("tools", cli_tools_mod);
        fr_exe.root_module.addImport("server", cli_server_mod);
        fr_exe.root_module.addImport("training", cli_training_mod);
        fr_exe.root_module.addImport("ollama_client", cli_ollama_mod);
        fr_exe.root_module.addImport("turing_test", cli_turing_mod);
        fr_exe.root_module.addImport("geo_math", geo_math_mod);
        fr_exe.root_module.addImport("live_feeds", live_feeds_mod);
        fr_exe.root_module.addImport("face_detect", face_detect_mod);
        fr_exe.root_module.addImport("face_recognize", face_recognize_mod);
        fr_exe.root_module.addImport("face_track", face_track_mod);
        fr_exe.root_module.addImport("gaze_headpose", gaze_headpose_mod);
        fr_exe.root_module.addImport("hud", hud_mod);
        fr_exe.root_module.addImport("face_attributes", face_attributes_mod);
        fr_exe.root_module.addImport("face_quality", face_quality_mod);
        fr_exe.root_module.addImport("anti_spoofing", anti_spoofing_mod);
        fr_exe.root_module.addImport("face_analyzer", face_analyzer_mod);
        fr_exe.root_module.addImport("globe_render", globe_render_mod);
        fr_exe.root_module.addImport("camera", camera_mod);
        fr_exe.root_module.addImport("voice_command", voice_command_mod);
        fr_exe.root_module.addImport("compress", compress_mod);
        fr_exe.root_module.addImport("corpus_store", corpus_store_mod);
        fr_exe.root_module.addImport("openai_client", openai_mod);
        fr_exe.root_module.addImport("env_loader", env_loader_mod);
        regression_step.dependOn(&b.addRunArtifact(fr_exe).step);
        // WASM and HTML artifacts are verified by checks 11/12
        regression_step.dependOn(wasm_step);
        regression_step.dependOn(html_step);
    }

    // === Master Node Publish Step ===
    // CI/CD gate: only builds that pass the full regression become publishable.
    // Publishes universe.html + qstar_corpus.qsc + qstar_llm.wasm +
    // seed_manifest.json into zig-out/master/ (the autoupdate channel).

    const master_step = b.step("master", "CI/CD gate: regression + build + publish quine payloads to zig-out/master/");
    {
        const mp_exe = b.addExecutable(.{
            .name = "master_publish",
            .root_source_file = b.path("src/master_publish.zig"),
            .target = target,
            .optimize = optimize,
        });
        const run_mp = b.addRunArtifact(mp_exe);
        // Publish must run strictly after the html rebuild (sibling deps of
        // master_step have no ordering guarantee on their own).
        run_mp.step.dependOn(html_step);
        master_step.dependOn(&run_mp.step);
        master_step.dependOn(regression_step);
        master_step.dependOn(html_step);
    }

    // === Maple Benchmark Step ===

    const maple_bench_step = b.step("maple-bench", "Run dedicated Maple device benchmark over LAN");
    {
        const mb_exe = b.addExecutable(.{
            .name = "maple_bench",
            .root_source_file = b.path("tests/maple_bench.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        mb_exe.root_module.addImport("maple_client", maple_client_mod);
        mb_exe.root_module.addImport("fixed_point", fixed_point_mod);
        mb_exe.root_module.addImport("ollama_client", ollama_mod);
        mb_exe.root_module.addImport("env_loader", env_loader_mod);

        // Agent module for maple bench
        const mb_agent_mod = b.addModule("agent", .{
            .root_source_file = b.path("src/agent.zig"),
            .target = target,
            .optimize = optimize,
        });
        mb_agent_mod.addImport("fixed_point", fixed_point_mod);
        mb_agent_mod.addImport("bpe_tokenizer", bpe_mod);
        mb_agent_mod.addImport("sampling", sampling_mod);
        mb_agent_mod.addImport("state_store", state_store_mod);
        mb_agent_mod.addImport("face_sync", face_sync_mod);
        const mb_lat_mod = b.addModule("lattice", .{
            .root_source_file = b.path("src/lattice.zig"),
            .target = target,
            .optimize = optimize,
        });
        mb_agent_mod.addImport("lattice", mb_lat_mod);
        const mb_kg_mod = b.addModule("knowledge_graph", .{
            .root_source_file = b.path("src/knowledge_graph.zig"),
            .target = target,
            .optimize = optimize,
        });
        mb_kg_mod.addImport("fixed_point", fixed_point_mod);
        mb_kg_mod.addImport("lattice", mb_lat_mod);
        mb_agent_mod.addImport("knowledge_graph", mb_kg_mod);
        mb_agent_mod.addImport("corpus_seed", corpus_seed_mod);
        const mb_mem_mod = b.addModule("memory", .{
            .root_source_file = b.path("src/memory.zig"),
            .target = target,
            .optimize = optimize,
        });
        mb_agent_mod.addImport("memory", mb_mem_mod);
        const mb_perc_mod = b.addModule("perception", .{
            .root_source_file = b.path("src/perception.zig"),
            .target = target,
            .optimize = optimize,
        });
        mb_perc_mod.addImport("fixed_point", fixed_point_mod);
        mb_agent_mod.addImport("perception", mb_perc_mod);
        const mb_metacog_mod = b.addModule("metacognition_engine", .{
            .root_source_file = b.path("src/metacognition_engine.zig"),
            .target = target,
            .optimize = optimize,
        });
        mb_agent_mod.addImport("metacognition_engine", mb_metacog_mod);
        const mb_dyn_routes_mod2 = b.addModule("dynamic_routes", .{
            .root_source_file = b.path("src/dynamic_routes.zig"),
            .target = target,
            .optimize = optimize,
        });
        mb_metacog_mod.addImport("dynamic_routes", mb_dyn_routes_mod2);
        mb_metacog_mod.addImport("q128", q128_mod);
        mb_agent_mod.addImport("dynamic_routes", mb_dyn_routes_mod2);
        const mb_trivium_mod = b.addModule("trivium", .{
            .root_source_file = b.path("src/trivium.zig"),
            .target = target,
            .optimize = optimize,
        });
        mb_agent_mod.addImport("trivium", mb_trivium_mod);
        const mb_quadrivium_mod = b.addModule("quadrivium", .{
            .root_source_file = b.path("src/quadrivium.zig"),
            .target = target,
            .optimize = optimize,
        });
        mb_quadrivium_mod.addImport("fixed_point", fixed_point_mod);
        mb_agent_mod.addImport("quadrivium", mb_quadrivium_mod);
        const mb_corpus_learner_mod = b.addModule("corpus_learner", .{
            .root_source_file = b.path("src/corpus_learner.zig"),
            .target = target,
            .optimize = optimize,
        });
        mb_corpus_learner_mod.addImport("trivium", mb_trivium_mod);
        mb_corpus_learner_mod.addImport("quadrivium", mb_quadrivium_mod);
        mb_corpus_learner_mod.addImport("dynamic_routes", mb_dyn_routes_mod2);
        mb_agent_mod.addImport("corpus_learner", mb_corpus_learner_mod);
        const mb_voice_codec_mod = b.addModule("voice_codec", .{
            .root_source_file = b.path("src/voice_codec.zig"),
            .target = target,
            .optimize = optimize,
        });
        mb_voice_codec_mod.addImport("fixed_point", fixed_point_mod);
        mb_agent_mod.addImport("voice_codec", mb_voice_codec_mod);
        mb_exe.root_module.addImport("agent", mb_agent_mod);
        mb_exe.root_module.addImport("bpe_tokenizer", bpe_mod);

        // Wire mesh modules (always available from src/)
        mb_exe.root_module.addImport("mesh", mesh_mod);
        mb_exe.root_module.addImport("p2p_types", p2p_types_mod);
        mb_exe.root_module.addImport("relay_router", relay_router_mod);

        const mb_run = b.addRunArtifact(mb_exe);
        if (b.args) |args| {
            mb_run.addArgs(args);
        }
        maple_bench_step.dependOn(&mb_run.step);
    }

    // === Seed Compression Step ===
    const seed_step = b.step("seed", "Compress agent state to zig-out/qstar_seed.bin");
    const seed_exe = b.addExecutable(.{
        .name = "qstar_seed",
        .root_source_file = b.path("src/seed_compressor.zig"),
        .target = target,
        .optimize = optimize,
    });
    seed_exe.root_module.addImport("fixed_point", fixed_point_mod);
    seed_exe.root_module.addImport("holographic", holographic_mod);
    seed_exe.root_module.addImport("compress", compress_mod);
    seed_exe.root_module.addImport("qr_nest", qr_nest_mod);
    seed_exe.root_module.addImport("fp_bridge", fp_bridge_mod);
    const seed_install = b.addInstallArtifact(seed_exe, .{
        .dest_dir = .{ .override = .{ .custom = "seed" } },
    });
    seed_step.dependOn(&seed_install.step);

    // HTML build depends on seed for embedding compressed agent state
    html_step.dependOn(seed_step);
}
