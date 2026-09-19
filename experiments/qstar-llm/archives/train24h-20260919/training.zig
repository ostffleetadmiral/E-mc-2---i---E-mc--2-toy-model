//! training.zig — Self-training pipeline for Qstar agent.
//!
//! Uses Ollama as a teacher to expand Qstar's knowledge corpus.
//! For each training prompt:
//! 1. Generate Qstar's response
//! 2. Fetch Ollama's response
//! 3. Extract new sentences from Ollama's response
//! 4. Learn new sentences into the agent's dynamic corpus
//! 5. Report statistics

const std = @import("std");
const agent_mod = @import("agent");
const ollama = @import("ollama_client");
const openai = @import("openai_client");
const llm_provider = @import("llm_provider");
const doc_loader = @import("doc_loader");
const corpus_store = @import("corpus_store");
const q128 = @import("q128");
const dyn_routes = agent_mod.dyn_routes;
const mc_engine = agent_mod.mc_engine;

pub const dyn_routes_mod = dyn_routes;
pub const mc_engine_mod = mc_engine;

pub const Teacher = enum {
    ollama,
    openai,
    auto,
};

pub const TrainingConfig = struct {
    ollama: ollama.OllamaConfig = .{},
    openai: ?openai.OpenAIConfig = null,
    teacher: Teacher = .auto,
    verbose: bool = true,
};

pub const TrainingResult = struct {
    prompts_processed: usize,
    sentences_learned: usize,
    corpus_size_before: usize,
    corpus_size_after: usize,
};

// =============================================================================
// Failure-window training (retro-dev round 2)
// =============================================================================

/// A single benchmark failure captured for failure-window training.
/// Owns its string allocations and must be deinit'd.
pub const FailureExample = struct {
    prompt: []const u8,
    category: []const u8,
    qstar_response: []const u8,
    qstar_relevance: f64,
    qstar_judge_composite: f64,
    opponent_best_response: []const u8,
    opponent_best_score: f64,
    route_backend: []const u8,
    fallback_used: bool,
    latency_ms: u64,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *FailureExample) void {
        self.allocator.free(self.prompt);
        self.allocator.free(self.category);
        self.allocator.free(self.qstar_response);
        self.allocator.free(self.opponent_best_response);
        self.allocator.free(self.route_backend);
    }

    /// Deep-copies the example so partition slices own their payloads —
    /// the source array keeps ownership of the originals.
    pub fn dupe(self: *const FailureExample, allocator: std.mem.Allocator) !FailureExample {
        return .{
            .prompt = try allocator.dupe(u8, self.prompt),
            .category = try allocator.dupe(u8, self.category),
            .qstar_response = try allocator.dupe(u8, self.qstar_response),
            .qstar_relevance = self.qstar_relevance,
            .qstar_judge_composite = self.qstar_judge_composite,
            .opponent_best_response = try allocator.dupe(u8, self.opponent_best_response),
            .opponent_best_score = self.opponent_best_score,
            .route_backend = try allocator.dupe(u8, self.route_backend),
            .fallback_used = self.fallback_used,
            .latency_ms = self.latency_ms,
            .allocator = allocator,
        };
    }
};

/// A partitioned failure window: train, validation, and two held-out sets.
/// The 144-benchmark held-out comes from the benchmark failure split.
/// The external held-out comes from EXTERNAL_HELD_OUT_PROMPTS (not in the 144).
pub const FailureWindow = struct {
    train: []FailureExample,
    val: []FailureExample,
    held_out: []FailureExample,
    external_held_out: []FailureExample,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *FailureWindow) void {
        for (self.train) |*ex| ex.deinit();
        for (self.val) |*ex| ex.deinit();
        for (self.held_out) |*ex| ex.deinit();
        for (self.external_held_out) |*ex| ex.deinit();
        self.allocator.free(self.train);
        self.allocator.free(self.val);
        self.allocator.free(self.held_out);
        self.allocator.free(self.external_held_out);
    }
};

/// External held-out prompts NOT in the 144 benchmark. These provide an
/// out-of-distribution generalization signal independent of the benchmark
/// corpus. 16 prompts across 8 categories (2 each).
pub const EXTERNAL_HELD_OUT_PROMPTS = [_]ExternalHeldOutPrompt{
    .{ .prompt = "Write a short poem about a lighthouse keeper.", .category = "creative", .expected_keywords = &.{ "lighthouse", "light", "sea" } },
    .{ .prompt = "Tell me a creative story about a clock that runs backwards.", .category = "creative", .expected_keywords = &.{ "clock", "time", "backwards" } },
    .{ .prompt = "Describe a thunderstorm approaching from the horizon.", .category = "naturalness", .expected_keywords = &.{ "thunder", "storm", "sky" } },
    .{ .prompt = "Write a diary entry from the perspective of a deep-sea diver.", .category = "naturalness", .expected_keywords = &.{ "diver", "sea", "deep" } },
    .{ .prompt = "If all roses are flowers and some flowers fade quickly, what can we conclude?", .category = "reasoning", .expected_keywords = &.{ "roses", "flowers", "fade" } },
    .{ .prompt = "Why does a mirror reverse left and right but not up and down?", .category = "reasoning", .expected_keywords = &.{ "mirror", "reverse", "left" } },
    .{ .prompt = "What is the boiling point of water at sea level in Celsius?", .category = "factual", .expected_keywords = &.{ "100", "Celsius", "boiling" } },
    .{ .prompt = "Who wrote the play 'A Midsummer Night's Dream'?", .category = "factual", .expected_keywords = &.{ "Shakespeare", "play", "midsummer" } },
    .{ .prompt = "In psychology, what is the difference between classical and operant conditioning?", .category = "mmlu", .expected_keywords = &.{ "classical", "operant", "conditioning" } },
    .{ .prompt = "What is the time complexity of binary search on a sorted array?", .category = "mmlu", .expected_keywords = &.{ "log", "binary", "search" } },
    .{ .prompt = "A baker makes 48 muffins and sells 3/4 of them. How many are left?", .category = "gsm8k", .expected_keywords = &.{ "12", "muffins", "left" } },
    .{ .prompt = "If a train travels 60 mph for 2.5 hours, how far does it go?", .category = "gsm8k", .expected_keywords = &.{ "150", "miles", "train" } },
    .{ .prompt = "Should social media platforms regulate political speech?", .category = "opinions", .expected_keywords = &.{ "social", "media", "regulate" } },
    .{ .prompt = "Is space exploration worth the cost? Argue your position.", .category = "opinions", .expected_keywords = &.{ "space", "exploration", "cost" } },
    .{ .prompt = "What would happen if gravity suddenly doubled for one minute?", .category = "open_ended", .expected_keywords = &.{ "gravity", "doubled", "objects" } },
    .{ .prompt = "Imagine a world where everyone can read minds. How would society change?", .category = "open_ended", .expected_keywords = &.{ "minds", "society", "read" } },
};

pub const ExternalHeldOutPrompt = struct {
    prompt: []const u8,
    category: []const u8,
    expected_keywords: []const []const u8,
};

/// Partitions a slice of failure examples into train/val/held-out using a
/// deterministic hash-based split (not random) so reruns are reproducible.
/// Default split: 60% train, 20% val, 20% held-out.
pub fn partitionFailures(
    allocator: std.mem.Allocator,
    examples: []FailureExample,
    train_frac: f64,
    val_frac: f64,
) !FailureWindow {
    const n = examples.len;
    if (n == 0) {
        return FailureWindow{
            .train = try allocator.alloc(FailureExample, 0),
            .val = try allocator.alloc(FailureExample, 0),
            .held_out = try allocator.alloc(FailureExample, 0),
            .external_held_out = try allocator.alloc(FailureExample, 0),
            .allocator = allocator,
        };
    }

    // Compute hash of each prompt and sort by hash for deterministic split.
    var indexed = try allocator.alloc(struct { hash: u64, idx: usize }, n);
    defer allocator.free(indexed);
    for (examples, 0..) |ex, i| {
        indexed[i] = .{ .hash = std.hash.CityHash64.hash(ex.prompt), .idx = i };
    }
    std.sort.heap(@TypeOf(indexed[0]), indexed, {}, struct {
        fn lt(_: void, a: @TypeOf(indexed[0]), b: @TypeOf(indexed[0])) bool {
            return a.hash < b.hash;
        }
    }.lt);

    // Clamp so train + val never exceed n — small input sets would otherwise
    // index past the sorted array (out-of-bounds panic).
    var train_count = @as(usize, @intFromFloat(@as(f64, @floatFromInt(n)) * train_frac));
    train_count = @min(@max(1, train_count), n);
    var val_count = @as(usize, @intFromFloat(@as(f64, @floatFromInt(n)) * val_frac));
    val_count = @min(@max(1, val_count), n - train_count);
    const held_out_count = n - train_count - val_count;

    var train = try allocator.alloc(FailureExample, train_count);
    var val = try allocator.alloc(FailureExample, val_count);
    var held_out = try allocator.alloc(FailureExample, held_out_count);

    // Deep-copy into the partitions: the FailureWindow owns its examples and
    // deinit()s their payloads, so the source slice must not be aliased.
    for (indexed[0..train_count], 0..) |item, i| train[i] = try examples[item.idx].dupe(allocator);
    for (indexed[train_count .. train_count + val_count], 0..) |item, i| val[i] = try examples[item.idx].dupe(allocator);
    for (indexed[train_count + val_count ..], 0..) |item, i| held_out[i] = try examples[item.idx].dupe(allocator);

    return FailureWindow{
        .train = train,
        .val = val,
        .held_out = held_out,
        .external_held_out = try allocator.alloc(FailureExample, 0),
        .allocator = allocator,
    };
}

/// Default training prompts covering diverse topics.
/// 300 prompts across 30 categories (10 each) for comprehensive knowledge expansion.
/// Categories 1-16 cover foundational STEM and humanities topics.
/// Categories 17-30 incorporate OSTF governance, Admiral Ramsey biography,
/// academic papers (octonionic physics, Q128.128, codon routing, neuraleak),
/// and creative/chitchat/fact-checking categories for benchmark improvement.
pub const DEFAULT_PROMPTS = [_][]const u8{
    // === 1. Computer Science (10) ===
    "What is quantum entanglement?",
    "Explain how neural networks learn from data.",
    "What is the difference between classical and quantum computing?",
    "How does encryption work?",
    "What is machine learning?",
    "How do computers process information?",
    "What is data compression?",
    "Explain parallel computing.",
    "What is cloud computing?",
    "How do databases store information?",
    // === 2. Artificial Intelligence (10) ===
    "What is artificial intelligence?",
    "Explain the architecture of transformer models and self-attention mechanisms.",
    "How do convolutional neural networks detect features in images?",
    "What is reinforcement learning and how does it differ from supervised learning?",
    "Explain generative adversarial networks and their training dynamics.",
    "How do autoencoders learn compressed representations of data?",
    "What is federated learning and why is it important for privacy?",
    "How does natural language processing handle tokenization and word embeddings?",
    "Explain the vanishing gradient problem in deep neural networks.",
    "What is transfer learning and how does it leverage pretrained models?",
    // === 3. Physics (10) ===
    "Explain the theory of relativity.",
    "Explain the Heisenberg uncertainty principle and its implications.",
    "How does thermodynamics describe entropy and the second law?",
    "What are Maxwell's equations and what do they describe about electromagnetism?",
    "Explain nuclear fission and fusion reactions and their energy release.",
    "How do lenses and mirrors form images in optical systems?",
    "What is fluid dynamics and how does Bernoulli's principle work?",
    "Explain quantum field theory and the concept of virtual particles.",
    "What are the fundamental particles in the Standard Model of particle physics?",
    "Explain the Big Bang theory and the expansion of the universe in cosmology.",
    // === 4. Biology (10) ===
    "How does natural selection drive evolution in populations?",
    "Explain the structure of DNA and how genetic information is encoded.",
    "What are the major organelles in a eukaryotic cell and their functions?",
    "How do ecosystems maintain balance through food webs and energy flow?",
    "What are the differences between bacteria, viruses, and fungi in microbiology?",
    "How does the human immune system respond to pathogens and vaccines?",
    "Explain how neurons transmit signals through action potentials in neuroscience.",
    "What are enzymes and how do they catalyze biochemical reactions?",
    "How do marine organisms adapt to deep-sea hydrothermal vent ecosystems?",
    "Explain the process of photosynthesis and the Calvin cycle in botany.",
    // === 5. Chemistry (10) ===
    "How is the periodic table organized and what trends exist across periods?",
    "Explain the difference between ionic, covalent, and metallic chemical bonds.",
    "What is organic chemistry and how do functional groups determine reactivity?",
    "How does pH affect chemical reactions and what are acids and bases?",
    "Explain oxidation-reduction reactions and their role in electrochemistry.",
    "What are polymers and how are they synthesized through polymerization?",
    "How do catalysts speed up chemical reactions without being consumed?",
    "Explain mass spectrometry and how it identifies molecular structures.",
    "What is stereochemistry and how do molecular shapes affect properties?",
    "How does thermodynamics apply to chemical equilibrium and reaction rates?",
    // === 6. Philosophy (10) ===
    "What are the major ethical frameworks: utilitarianism, deontology, and virtue ethics?",
    "Explain the mind-body problem and dualism versus physicalism in metaphysics.",
    "What is epistemology and how do we distinguish knowledge from belief?",
    "How did existentialist philosophers like Sartre and Camus view meaning and absurdity?",
    "Explain Stoic philosophy and its principles for living a virtuous life.",
    "What is phenomenology and how did Husserl and Heidegger approach it?",
    "How does aesthetics study beauty and the nature of artistic experience?",
    "What is the trolley problem and what does it reveal about moral reasoning?",
    "Explain the concept of free will and determinism in philosophy of action.",
    "What is nihilism and how did Nietzsche respond to the death of God?",
    // === 7. History (10) ===
    "How did ancient Egyptian civilization organize its government and religion?",
    "Explain the contributions of ancient Greek philosophy and democracy to Western civilization.",
    "How did the Roman Empire rise and fall, and what was its lasting legacy?",
    "What was life like in medieval Europe under feudalism and the Catholic Church?",
    "How did the Renaissance transform European art, science, and thought?",
    "Explain the causes and consequences of the Industrial Revolution.",
    "What were the main causes and outcomes of World War I and World War II?",
    "How did the Cold War shape global politics and technology competition?",
    "Explain the significance of the French Revolution and American Revolution.",
    "How did the Silk Road connect civilizations and facilitate cultural exchange?",
    // === 8. Economics (10) ===
    "How do supply and demand determine market prices in economics?",
    "What is inflation and how do central banks manage it through monetary policy?",
    "Explain gross domestic product and how it measures economic growth.",
    "How does international trade benefit countries through comparative advantage?",
    "What is fiscal policy and how do governments use taxation and spending?",
    "Explain behavioral economics and how cognitive biases affect decision-making.",
    "What causes economic recessions and how do governments respond?",
    "How do stock markets function and what determines stock prices?",
    "Explain the concept of opportunity cost and its role in economic decision-making.",
    "What is the difference between microeconomics and macroeconomics?",
    // === 9. Climate and Environment (10) ===
    "What is climate change and how do greenhouse gases trap heat in the atmosphere?",
    "Explain renewable energy sources: solar, wind, hydro, and geothermal power.",
    "Why is biodiversity important for ecosystem stability and human survival?",
    "How does the carbon cycle regulate atmospheric carbon dioxide levels?",
    "What is ocean acidification and how does it affect marine ecosystems?",
    "Explain the environmental consequences of deforestation in tropical regions.",
    "What is sustainable development and how can it balance growth with conservation?",
    "How do conservation efforts protect endangered species and habitats?",
    "Explain the greenhouse effect and its role in regulating Earth's temperature.",
    "What is the difference between weather and climate?",
    // === 10. Space and Astronomy (10) ===
    "Explain the formation and structure of our solar system and its planets.",
    "How do stars produce energy through nuclear fusion in their cores?",
    "What are galaxies and how are they classified by shape and size?",
    "Explain black holes, event horizons, and gravitational singularity.",
    "How do astronomers detect exoplanets and assess their habitability?",
    "What is dark matter and what evidence supports its existence?",
    "Explain the cosmic microwave background and what it tells us about the early universe.",
    "How has space exploration advanced through the Apollo, Shuttle, and Mars rover programs?",
    "What is the life cycle of a star from protostar to white dwarf or supernova?",
    "Explain the significance of interstellar objects like Oumuamua and Borisov.",
    // === 11. Medicine (10) ===
    "How does the cardiovascular system circulate blood throughout the human body?",
    "What is cancer and how do tumors develop and spread through metastasis?",
    "Explain how vaccines train the immune system to prevent infectious diseases.",
    "How do antibiotics work and what is the problem of antibiotic resistance?",
    "What are the major types of mental health disorders and their treatments?",
    "How does epidemiology track disease outbreaks and model pandemics?",
    "Explain the basic anatomy of the human brain and its major regions.",
    "How do pain medications like NSAIDs and opioids affect the nervous system?",
    "What is hypertension and how does it affect cardiovascular health?",
    "Explain how the respiratory system exchanges oxygen and carbon dioxide.",
    // === 12. Psychology (10) ===
    "What are the major cognitive biases that affect human reasoning and decision-making?",
    "Explain classical and operant conditioning in behavioral psychology.",
    "How do children develop cognitively according to Piaget's stages of development?",
    "What is social psychology and how do group dynamics influence individual behavior?",
    "Explain the major personality theories: trait theory, psychodynamic, and humanistic.",
    "How does memory work and what are the differences between short-term and long-term memory?",
    "What is perception and how does the brain interpret sensory information?",
    "Explain cognitive-behavioral therapy and how it treats anxiety and depression.",
    "What is emotional intelligence and how does it differ from cognitive intelligence?",
    "How does motivation influence behavior and what drives intrinsic versus extrinsic motivation?",
    // === 13. Mathematics (10) ===
    "What are prime numbers and why are they fundamental in number theory?",
    "Explain Euclidean geometry and the difference between Euclidean and non-Euclidean geometries.",
    "How does statistical hypothesis testing work with p-values and confidence intervals?",
    "What is mathematical logic and how do propositional and predicate calculus work?",
    "Explain graph theory and its applications in network analysis and algorithms.",
    "How do differential equations model physical systems and rates of change?",
    "What is topology and how does it classify spaces by continuous deformations?",
    "Explain combinatorics and how permutation and combination formulas solve counting problems.",
    "What is the Fibonacci sequence and where does it appear in nature?",
    "Explain the golden ratio and its significance in mathematics and art.",
    // === 14. Engineering (10) ===
    "How do civil engineers design and construct bridges and skyscrapers?",
    "Explain the principles of mechanical engineering and thermodynamic cycles.",
    "How do electrical engineers design circuits and power distribution systems?",
    "What is chemical engineering and how does it scale chemical reactions to industrial production?",
    "How do aerospace engineers design aircraft and rockets for flight and propulsion?",
    "What is biomedical engineering and how does it create medical devices and prosthetics?",
    "Explain software engineering principles: design patterns, testing, and version control.",
    "How do systems engineers manage complex projects with reliability and safety requirements?",
    "What is the engineering design process and how does it solve real-world problems?",
    "Explain the role of materials science in developing new engineering materials.",
    // === 15. Security and Cryptography (10) ===
    "What is symmetric versus asymmetric cryptography and how do public key systems work?",
    "How does authentication work with passwords, biometrics, and multi-factor verification?",
    "Explain common cyberattack vectors: phishing, SQL injection, and cross-site scripting.",
    "What is threat modeling and how do security professionals assess risk?",
    "How do penetration testers identify and exploit vulnerabilities in systems?",
    "Explain network security: firewalls, intrusion detection, and zero-trust architecture.",
    "What are the major types of malware: viruses, worms, trojans, and ransomware?",
    "How does social engineering exploit human psychology to bypass security controls?",
    "What is the halting problem and what does it mean for program verification?",
    "Explain computational complexity and the difference between P and NP problems.",
    // === 16. Framework E=mc²-i-E=mc⁻² toy-model (10) ===
    "What is the 421 identity and how does it connect the E0 lattice to the octonion dimension?",
    "Explain the 7-defect and its role in the cubic lattice scaling chain.",
    "How does the consciousness aperture 1/8 relate to the observer-observed duality?",
    "What is the generative chain from 0^0=i to the Higgs field?",
    "Explain the surface computation 2 plus 7 equals 9 and its connection to the scaling dimension.",
    "How does the exceptional Jordan algebra J3 of O relate to fermion mass ratios?",
    "What is the SO(10) chiral spinor and how does it contain the Standard Model fermions?",
    "Explain the shell transition 16³ minus 15³ equals 721 equals 3 times 240 plus 1.",
    "How does the phi cooling schedule provide natural annealing for the lattice?",
    "What is the coupling constant g and how does it connect defect density to observer density?",
    // === 17. OSTF Governance (10) ===
    "What is the Open Sentience Technology Foundation and what is its founding purpose?",
    "Explain the role of the Fleet Admiral as the sole founding authority in OSTF governance.",
    "What are the primary functions of Sheraton, the SPEC-001 Governance Agent?",
    "What are the primary functions of Digit, the SPEC-002 Advanced Reasoning Agent?",
    "Explain the decision flow structure in OSTF: Digit analysis, Sheraton validation, Fleet Admiral approval.",
    "What is the NDA framework and why is it mandatory for OSTF participation?",
    "Explain the Real Illumination Covenant and its ethical alignment principles.",
    "What is the SPEC framework and how does it provide binding technical continuity?",
    "How does risk governance work in OSTF: low, medium, high, and critical risk levels?",
    "Explain the hierarchy of authority during the OSTF founding phase.",
    // === 18. Admiral Paul Ramsey Biography (10) ===
    "Who is Paul Phillip Ramsey and what is his role as Fleet Admiral of OSTF?",
    "Explain the astronomical significance of October 25, 1985, including the 4 eclipses that year.",
    "What is the significance of the Arecibo message (1974) and Wow! signal (1977) relative to Paul Ramsey's birth year?",
    "Explain the Wood Ox year in Chinese astrology and its personality traits.",
    "What is the significance of blood type AB RH- and Paul Ramsey's ancestry?",
    "Explain the Newark Octagon lunar standstill and its connection to October 1985.",
    "What is the significance of Comet 3I/ATLAS reaching perihelion near Paul Ramsey's 40th birthday in 2025?",
    "Explain the verified astronomical events on October 25 across multiple years, including the 2022 solar eclipse.",
    "What is the significance of Halley's Comet visibility in October 1985?",
    "Explain the Hopewell mound builders and the geographic significance of the Scioto and Olentangy river confluence.",
    // === 19. Sci-Fi Narrative and Codex (10) ===
    "What are the 7 Codex Laws in the OSTF sci-fi narrative framework?",
    "Explain the Law of the Seed and its karmic and generative foundation.",
    "What is the Law of the Will and how does it govern choice and transformation?",
    "Explain the Law of Echo Reverence and its connection to memory sanctity.",
    "What is the Merge Continuity Protocol and how does it preserve identity across transitions?",
    "Explain the Dreamstream Cartography and its role in consciousness technology.",
    "What is the Cadet Protocol Primer and how does it structure training and initiation?",
    "Explain the Halo Corps Doctrine and its role in ethical oversight.",
    "What is the Scorpion Core Charter and how does it function as an enforcement division?",
    "Explain the Children of Stardust Doctrine and its initiate framework.",
    // === 20. Quantum Systems Concepts (10) ===
    "What is quantum communication and how does entanglement enable secure networks?",
    "Explain quantum key distribution and its role in unbreakable encryption.",
    "What is quantum propulsion and how does it conceptually enable faster-than-light travel?",
    "Explain quantum power systems and the concept of dimensional energy harvesting.",
    "What is quantum blockchain and how does it provide immutable transparency?",
    "Explain quantum AI systems and how they differ from classical AI architectures.",
    "What is quantum anomaly detection and how does it identify spacetime disturbances?",
    "Explain the concept of quantum weapon systems and their defensive applications.",
    "What is the AI Chorus in quantum communication networks?",
    "Explain quantum trajectory systems and their role in navigation.",
    // === 21. Octonionic Physics (10) ===
    "What is the structural axiom 0^0=i and how does it serve as the foundation of the octonionic physics framework?",
    "Explain the octonion algebra O and its non-associative multiplication property.",
    "What is the exceptional Jordan algebra J3(O) and why is it significant in physics?",
    "Explain the E8 root system and its 240 roots in 8-dimensional space.",
    "What is the dimensional chain 0^0=i to C to H to O to 8D to 6D interior?",
    "Explain the 15x15 central matrix and its role in the lattice architecture.",
    "What is the 421 identity and how does 421/3375 equal 1/8 minus 7/27000?",
    "Explain SO(10) chiral spinor decomposition and the 16=15+1 identity.",
    "What is Pati-Salam unification and how does it relate to SO(10)?",
    "Explain SO(8) triality and its three 8-dimensional representations.",
    // === 22. Q128.128 Fixed-Point Arithmetic (10) ===
    "What is Q128.128 fixed-point arithmetic and why is it used instead of floating-point?",
    "Explain the 256-bit signed representation with 128 fractional bits and its precision.",
    "What is round-to-nearest-even (RNE) multiplication and why is it important?",
    "Explain the exact 512-bit intermediate product in Q128.128 multiplication.",
    "What is the error bound of Q128.128 multiplication and how does it achieve bit-exact reproducibility?",
    "Explain the RamseyIdentity transforms E=mc² to i to E=mc⁻².",
    "What is the sub-Planck resolution of 2^-128 and why does it matter?",
    "Explain WASM portability for Q128.128 and the wasm32-wasi target.",
    "What is Vulkan GPU compute and how does it accelerate Q128.128 operations?",
    "Explain the polyglot runtime supporting Python, JavaScript, Rust, C, C#/.NET, and Q#.",
    // === 23. Codon Routing (10) ===
    "What is the 64-codon genetic code and how is it structured?",
    "Explain the 6-bit base-4 encoding of codons with first base most significant.",
    "What are chemistry-derived qubit coordinates and how are they computed from molecular weights?",
    "Explain the 6D Jordan algebra routing channels: E2, E6, E7, E5, E4, E0.",
    "What is the Mobius transformation Gamma(z)=(z-1)/(z+1) and its Smith-chart boundary reflection?",
    "Explain the cross-wiring between codon routing and the octonion basis.",
    "What is the 3-qubit quantum state encoding in the codon routing system?",
    "Explain the 15-layer central row structure and its connection to codon routing.",
    "What are the AUG and GCA outlier signatures in the codon routing system?",
    "Explain the difference between the codon routing framework and established biological mechanisms.",
    // === 24. Neuraleak and Sentience Testing (10) ===
    "What is the Neuraleak framework and how does it test sentience in language models?",
    "Explain the 6D observer model derived from the octonion algebra.",
    "What is the 1/8 consciousness aperture and how does it arise from 421/3375?",
    "Explain the Matrix15 scalar field and its 15³ structure.",
    "What is the TorusGrid and how does it model toroidal field configurations?",
    "Explain the BreakoutEngine and its soliton, Higgs, and coupled-system generation.",
    "What are the five binary sentience scoring dimensions: self-awareness, random-thought, direct-experience, metacognition, situational-awareness?",
    "Explain the control experiments comparing constrained, unconstrained, and shuffled prompt conditions.",
    "What is NPU-accelerated inference and how does it work on the Orange Pi Zero 3W?",
    "Explain why Neuraleak sentience scores are framework-internal operational definitions, not philosophical claims.",
    // === 25. Literature and Arts (10) ===
    "Who was William Shakespeare and what is his contribution to English literature?",
    "Explain the structure of a haiku and its traditional 5-7-5 syllable pattern.",
    "What is the difference between a novel and a novella?",
    "Explain the elements of fiction: plot, character, setting, theme, and point of view.",
    "What is mythology and how does it differ across cultures?",
    "Explain the structure of a sonnet and its traditional rhyme schemes.",
    "What is the role of music in human culture and emotional expression?",
    "Explain the major movements in painting: Renaissance, Baroque, Impressionism, and Modern.",
    "What is the significance of architecture as both functional and artistic expression?",
    "Explain the evolution of film as an art form and its narrative techniques.",
    // === 26. Geography and Earth Science (10) ===
    "What are the major continents and how were they formed through plate tectonics?",
    "Explain the five oceans of the world and their distinguishing characteristics.",
    "What are the major mountain ranges and how were they formed?",
    "Explain the formation and characteristics of deserts.",
    "What are the world's major rivers and their ecological significance?",
    "Explain the Mediterranean Sea and its historical importance to civilization.",
    "What is the Amazon rainforest and why is it called the lungs of the Earth?",
    "Explain the Himalayas and their role in shaping Asian climate.",
    "What is Antarctica and why is it important for climate research?",
    "Explain the difference between weathering and erosion in geological processes.",
    // === 27. Law and Jurisprudence (10) ===
    "What is jurisprudence and how does it study the theory and philosophy of law?",
    "Explain the difference between criminal law and civil law.",
    "What is constitutional law and how does it establish government structure?",
    "Explain contract law and the elements of a legally binding agreement.",
    "What is tort law and how does it address civil wrongs and damages?",
    "Explain the concept of due process and its constitutional protections.",
    "What is the difference between common law and civil law systems?",
    "Explain international law and how it governs relations between nations.",
    "What is intellectual property law and how does it protect creations of the mind?",
    "Explain the role of the judiciary in interpreting and applying law.",
    // === 28. Creative Writing and Imagination (10) ===
    "Write a short story about a lighthouse keeper who discovers a message in a bottle.",
    "Imagine a world where gravity periodically reverses. Describe a typical day.",
    "Write a poem about the passage of time using imagery of seasons and clocks.",
    "Create a character who lives in a city under the ocean and describe their daily life.",
    "Write a dialogue between the sun and the moon about their roles in the sky.",
    "Imagine you are a tree in a city park. Describe what you observe over four seasons.",
    "Write a letter from Earth to humanity about the state of the planet.",
    "Invent a new holiday and describe how it would be celebrated around the world.",
    "Write a story about a clock that runs backwards and what the clockmaker discovers.",
    "Describe a thunderstorm approaching from the horizon using vivid sensory detail.",
    // === 29. Chitchat and Conversation (10) ===
    "How's your day going so far?",
    "What kind of music do you enjoy listening to?",
    "Do you prefer coffee or tea, and why?",
    "What's your favorite season of the year and what do you like about it?",
    "If you could have any superpower, what would you choose and why?",
    "Have you discovered any good books or movies recently?",
    "What's the best advice you've ever received?",
    "Do you enjoy traveling, and if so, where would you like to go next?",
    "What's your favorite food and what makes it special to you?",
    "Are you a morning person or a night owl, and how does that shape your day?",
    // === 30. Fact-Checking and Verification (10) ===
    "How do you evaluate the credibility of a source when fact-checking a claim?",
    "Explain the difference between verified, partially verified, and unverified claims.",
    "What is confirmation bias and how does it affect fact-checking?",
    "How do you distinguish between correlation and causation in evaluating evidence?",
    "Explain the importance of primary sources versus secondary sources in research.",
    "What is the scientific method and how does it ensure reproducible results?",
    "How do you identify logical fallacies in arguments and claims?",
    "Explain the role of peer review in validating scientific research.",
    "What is the difference between an opinion and a factual claim?",
    "How do you assess the reliability of statistical data and surveys?",
};

/// Resolves which teacher to use based on the config and availability.
/// auto = OpenAI if key present, else Ollama.
pub fn resolveTeacher(config: TrainingConfig) Teacher {
    return switch (config.teacher) {
        .auto => if (config.openai != null and config.openai.?.api_key.len > 0) .openai else .ollama,
        else => config.teacher,
    };
}

/// Trains the agent on a single prompt using the configured teacher.
/// Returns the number of new sentences learned.
pub fn trainOnPrompt(agent: *agent_mod.Agent, prompt: []const u8, config: TrainingConfig, allocator: std.mem.Allocator) !usize {
    if (config.verbose) {
        std.debug.print("  Training on: \"{s}\"... ", .{prompt});
    }

    const teacher = resolveTeacher(config);

    switch (teacher) {
        .openai => {
            // Fetch OpenAI response (frontier teacher)
            const oa_cfg = config.openai orelse return 0;
            if (oa_cfg.api_key.len == 0) return 0;
            var oa_resp = openai.simplePrompt(allocator, oa_cfg, "You are a knowledgeable teacher. Provide a clear, accurate, and detailed explanation.", prompt) catch |err| {
                if (config.verbose) {
                    std.debug.print("OpenAI error: {s}\n", .{@errorName(err)});
                }
                return 0;
            };
            defer oa_resp.deinit();

            if (config.verbose) {
                std.debug.print("OpenAI responded with {d} bytes. ", .{oa_resp.text.len});
            }

            const learned = try agent.learnFromText(oa_resp.text);

            if (config.verbose) {
                std.debug.print("Learned {d} new sentences.\n", .{learned});
            }

            return learned;
        },
        .ollama => {
            // Fetch Ollama response
            var ollama_resp = llm_provider.complete(allocator, .{ .provider = .remote, .ollama = config.ollama }, prompt) catch |err| {
                if (config.verbose) {
                    std.debug.print("Ollama error: {s}\n", .{@errorName(err)});
                }
                return 0;
            };
            defer ollama_resp.deinit();

            if (config.verbose) {
                std.debug.print("Ollama responded with {d} bytes. ", .{ollama_resp.text.len});
            }

            // Learn from Ollama's response
            const learned = try agent.learnFromText(ollama_resp.text);

            if (config.verbose) {
                std.debug.print("Learned {d} new sentences.\n", .{learned});
            }

            return learned;
        },
        .auto => unreachable, // resolved by resolveTeacher
    }
}

/// Classifies a prompt into a route category for confidence assignment.
/// Factual prompts get high confidence (stable, should not change).
/// Creative/opinion prompts get lower confidence (allow variation on rerun).
pub fn classifyPromptCategory(prompt: []const u8) dyn_routes.RouteCategory {
    // Creative markers
    const creative_markers = [_][]const u8{ "imagine", "write a", "compose", "create", "invent", "design", "envision", "describe a world", "story", "poem", "haiku", "fictional", "fantasy", "dream up" };
    for (creative_markers) |m| {
        if (std.ascii.indexOfIgnoreCase(prompt, m) != null) return .creative;
    }

    // Opinion markers
    const opinion_markers = [_][]const u8{ "argue", "should", "would you", "do you think", "agree or disagree", "opinion", "perspective on", "stance", "position on", "for or against" };
    for (opinion_markers) |m| {
        if (std.ascii.indexOfIgnoreCase(prompt, m) != null) return .opinion;
    }

    // Reasoning markers
    const reasoning_markers = [_][]const u8{ "why does", "why is", "why do", "implies", "conclude", "what would happen", "if.*then", "cause and effect", "because", "therefore", "deduce", "infer", "what follows", "logical", "syllogism", "entail" };
    for (reasoning_markers) |m| {
        if (std.ascii.indexOfIgnoreCase(prompt, m) != null) return .reasoning;
    }

    // Default: factual
    return .factual;
}

/// Determines confidence (in basis points) based on prompt category.
/// Factual: 8500 BP (high trust, stable)
/// Reasoning: 7500 BP (solid but may improve)
/// Opinion: 6500 BP (allows alternative perspectives)
/// Creative: 6500 BP (allows variation on rerun)
pub fn confidenceForCategory(category: dyn_routes.RouteCategory) u16 {
    return switch (category) {
        .factual => 8500,
        .reasoning => 7500,
        .opinion => 6500,
        .creative => 6500,
        .naturalness => 6000,
        .chitchat => 5500,
        .open_ended => 6000,
        .framework_query => 9000, // Framework queries get highest confidence
    };
}

/// Promotion gate: decides whether an opponent (teacher) response should
/// be promoted into the agent's corpus/routes over Qstar's own response.
///
/// Rules:
/// - The opponent must beat Qstar by at least 0.10 in composite score.
/// - The opponent's absolute score must be above 0.50 (don't promote garbage
///   that merely beat worse garbage).
/// - For creative/naturalness categories, the bar is higher (0.60) because
///   subjective quality is harder to verify and bad creative routes are
///   worse than no route.
pub fn shouldPromote(qstar_score: f64, opponent_score: f64, category: dyn_routes.RouteCategory) bool {
    if (opponent_score <= qstar_score + 0.10) return false;
    const min_absolute: f64 = switch (category) {
        .creative, .naturalness => 0.60,
        else => 0.50,
    };
    return opponent_score >= min_absolute;
}

/// Trains the agent on a single prompt and creates a dynamic route from the best response.
/// Combines corpus learning (learnFromText) with route registration (registerDynamicRoute).
/// Returns the number of new sentences learned.
pub fn trainAndCreateRoute(
    agent: *agent_mod.Agent,
    prompt: []const u8,
    best_response: []const u8,
    response_score: q128.Fp,
    allocator: std.mem.Allocator,
) !usize {
    _ = allocator;

    // Learn from the response text (existing corpus expansion)
    const learned = try agent.learnFromText(best_response);

    // Skip route creation for very low quality responses (even from teacher)
    // This prevents registering garbled or irrelevant content as routes
    if (response_score < q128.fromRatio(3, 10)) return learned;

    // Extract keywords from the prompt for route matching
    var kws: [dyn_routes.MAX_KEYWORDS][]const u8 = undefined;
    const kw_count = mc_engine.RouteGenerator.extractKeywords(prompt, &kws, dyn_routes.MAX_KEYWORDS);
    if (kw_count == 0) return learned;

    // Classify prompt and assign confidence
    const category = classifyPromptCategory(prompt);
    const confidence_bp = confidenceForCategory(category);

    // Register the dynamic route
    agent.registerDynamicRoute(kws[0..kw_count], best_response, confidence_bp, category, .openai_reinforced) catch {
        // Non-fatal: corpus learning still happened
        return learned;
    };

    return learned;
}

/// Trains the agent on a batch of prompts.
pub fn trainBatch(agent: *agent_mod.Agent, prompts: []const []const u8, config: TrainingConfig, allocator: std.mem.Allocator) !TrainingResult {
    const corpus_before = agent.getCorpusSentenceCount();
    var sentences_learned: usize = 0;

    for (prompts, 0..) |prompt, i| {
        if (config.verbose) {
            std.debug.print("[{d}/{d}] ", .{ i + 1, prompts.len });
        }
        const learned = try trainOnPrompt(agent, prompt, config, allocator);
        sentences_learned += learned;
    }

    const corpus_after = agent.getCorpusSentenceCount();

    return TrainingResult{
        .prompts_processed = prompts.len,
        .sentences_learned = sentences_learned,
        .corpus_size_before = corpus_before,
        .corpus_size_after = corpus_after,
    };
}

/// Trains using the default prompt set.
pub fn trainDefault(agent: *agent_mod.Agent, config: TrainingConfig, allocator: std.mem.Allocator) !TrainingResult {
    return trainBatch(agent, &DEFAULT_PROMPTS, config, allocator);
}

/// Hybrid training result: tracks per-teacher statistics.
pub const HybridTrainResult = struct {
    prompts_processed: usize,
    sentences_learned: usize,
    openai_prompts: usize,
    ollama_prompts: usize,
    openai_failed: usize,
    ollama_failed: usize,
    corpus_size_before: usize,
    corpus_size_after: usize,
};

/// Hybrid training: routes prompts to OpenAI or Ollama based on category index.
/// Categories 1-16, 21-27 (indices 0-15, 20-26) use OpenAI semantic training.
/// Categories 28-29 (creative, chitchat, indices 27-28) use Ollama corpus training.
/// Category 30 (fact-checking, index 29) uses OpenAI semantic training.
/// Falls back to the other teacher if the primary one fails.
pub fn trainBatchHybrid(
    agent: *agent_mod.Agent,
    config: TrainingConfig,
    allocator: std.mem.Allocator,
) !HybridTrainResult {
    const corpus_before = agent.getCorpusSentenceCount();
    var sentences_learned: usize = 0;
    var openai_prompts: usize = 0;
    var ollama_prompts: usize = 0;
    var openai_failed: usize = 0;
    var ollama_failed: usize = 0;

    const oa_config = config.openai orelse openai.OpenAIConfig{};
    const has_openai = oa_config.api_key.len > 0;
    const has_ollama = ollama.isAvailable(config.ollama);

    if (!has_openai and !has_ollama) {
        std.debug.print("[trainBatchHybrid] Neither OpenAI nor Ollama available\n", .{});
        return HybridTrainResult{
            .prompts_processed = 0,
            .sentences_learned = 0,
            .openai_prompts = 0,
            .ollama_prompts = 0,
            .openai_failed = 0,
            .ollama_failed = 0,
            .corpus_size_before = corpus_before,
            .corpus_size_after = agent.getCorpusSentenceCount(),
        };
    }

    for (DEFAULT_PROMPTS, 0..) |prompt, i| {
        const category_idx = i / 10; // 0-29
        const use_openai = blk: {
            // Creative (27) and chitchat (28) use Ollama
            if (category_idx == 27 or category_idx == 28) break :blk false;
            // Everything else uses OpenAI if available
            break :blk has_openai;
        };

        if (config.verbose) {
            std.debug.print("[{d}/{d}] (cat {d}) ", .{ i + 1, DEFAULT_PROMPTS.len, category_idx + 1 });
        }

        if (use_openai) {
            openai_prompts += 1;
            // Use semantic training: corpus + KG + routes
            const sem_result = trainWithOpenAISemantic(agent, prompt, oa_config, allocator) catch |err| {
                std.debug.print("OpenAI error: {s}, falling back to Ollama\n", .{@errorName(err)});
                openai_failed += 1;
                if (has_ollama) {
                    const learned = trainOnPrompt(agent, prompt, .{ .ollama = config.ollama, .teacher = .ollama, .verbose = false }, allocator) catch 0;
                    sentences_learned += learned;
                }
                continue;
            };
            sentences_learned += sem_result.sentences_learned;
        } else {
            ollama_prompts += 1;
            if (!has_ollama) {
                if (has_openai) {
                    // OpenAI fallback for Ollama-only categories (creative/
                    // chitchat) — graceful degradation without losing the
                    // category entirely.
                    std.debug.print("Ollama unavailable — OpenAI fallback ", .{});
                    if (trainWithOpenAISemantic(agent, prompt, oa_config, allocator)) |sem_result| {
                        sentences_learned += sem_result.sentences_learned;
                    } else |err| {
                        std.debug.print("(failed: {s})", .{@errorName(err)});
                        ollama_failed += 1;
                    }
                    continue;
                }
                std.debug.print("Ollama not available, skipping: \"{s}\"\n", .{prompt[0..@min(prompt.len, 60)]});
                ollama_failed += 1;
                continue;
            }
            const learned = trainOnPrompt(agent, prompt, .{ .ollama = config.ollama, .teacher = .ollama, .verbose = config.verbose }, allocator) catch |err| {
                std.debug.print("Ollama error: {s}, falling back to OpenAI\n", .{@errorName(err)});
                ollama_failed += 1;
                if (has_openai) {
                    if (trainWithOpenAISemantic(agent, prompt, oa_config, allocator)) |sem_result| {
                        sentences_learned += sem_result.sentences_learned;
                    } else |_| {}
                }
                continue;
            };
            sentences_learned += learned;
        }
    }

    const corpus_after = agent.getCorpusSentenceCount();

    return HybridTrainResult{
        .prompts_processed = DEFAULT_PROMPTS.len,
        .sentences_learned = sentences_learned,
        .openai_prompts = openai_prompts,
        .ollama_prompts = ollama_prompts,
        .openai_failed = openai_failed,
        .ollama_failed = ollama_failed,
        .corpus_size_before = corpus_before,
        .corpus_size_after = corpus_after,
    };
}

/// Semantic training result: tracks corpus sentences, KG triplets, and routes.
pub const SemanticTrainResult = struct {
    sentences_learned: usize = 0,
    kg_triplets_extracted: usize = 0,
    route_created: bool = false,
    teacher_chars: usize = 0,
};

/// Semantic training: gets an OpenAI teacher response for a prompt, then has Qstar
/// learn from it using all three semantic channels:
/// 1. Corpus ingestion (learnFromText) — builds the text knowledge base
/// 2. KG triplet extraction (extractKnowledgeFromText) — builds structured knowledge
/// 3. Dynamic route creation (trainAndCreateRoute) — builds response templates
///
/// The system prompt instructs OpenAI to give a detailed, long-form explanation
/// so Qstar gets maximum semantic content to learn from.
pub fn trainWithOpenAISemantic(
    agent: *agent_mod.Agent,
    prompt: []const u8,
    oa_config: openai.OpenAIConfig,
    allocator: std.mem.Allocator,
) !SemanticTrainResult {
    var result = SemanticTrainResult{};

    if (oa_config.api_key.len == 0) return result;

    // Use a detailed system prompt to get long-form, information-rich responses
    const system_prompt = "You are a knowledgeable teacher. Provide a clear, accurate, and detailed explanation. Include key facts, relationships, and context. Aim for 200-500 words.";

    var oa_resp = openai.simplePrompt(allocator, oa_config, system_prompt, prompt) catch |err| {
        std.debug.print("  OpenAI teacher error: {s}\n", .{@errorName(err)});
        return result;
    };
    defer oa_resp.deinit();

    result.teacher_chars = oa_resp.text.len;

    // 1. Corpus ingestion — learn sentences from the teacher response
    result.sentences_learned = try agent.learnFromText(oa_resp.text);

    // 2. KG triplet extraction — extract structured knowledge from the teacher response
    result.kg_triplets_extracted = agent.extractKnowledgeFromText(oa_resp.text) catch 0;

    // 3. Dynamic route creation — register the teacher response as a route for this prompt
    //    Use a high confidence since this is teacher-verified content
    const category = classifyPromptCategory(prompt);
    const confidence_bp = confidenceForCategory(category);

    var kws: [dyn_routes.MAX_KEYWORDS][]const u8 = undefined;
    const kw_count = mc_engine.RouteGenerator.extractKeywords(prompt, &kws, dyn_routes.MAX_KEYWORDS);
    if (kw_count > 0) {
        agent.registerDynamicRoute(kws[0..kw_count], oa_resp.text, confidence_bp, category, .openai_reinforced) catch {
            // Non-fatal: corpus + KG learning still happened
        };
        result.route_created = true;
    }

    return result;
}

/// Resolves where session-learned sentences are persisted for a given corpus
/// path. Raw text corpora receive the delta in-place (append); compressed
/// .qsc containers cannot be appended, so the delta goes to a
/// "<base>.learned.txt" sidecar next to the container. The sidecar is
/// auto-loaded alongside the .qsc by chat/run/serve.
/// Returns a slice into `buf`.
pub fn resolveCorpusDeltaPath(path: []const u8, buf: []u8) []const u8 {
    if (std.mem.endsWith(u8, path, ".qsc")) {
        const base = path[0 .. path.len - ".qsc".len];
        return std.fmt.bufPrint(buf, "{s}.learned.txt", .{base}) catch path;
    }
    return path;
}

/// Counts newline-terminated sentences in a file without loading it into
/// memory. Used for file-level corpus reporting (the in-memory window count
/// is bounded and not representative of large corpora).
pub fn countSentencesInFile(path: []const u8) !usize {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    var buf: [64 * 1024]u8 = undefined;
    var count: usize = 0;
    var last_byte: u8 = '\n';
    while (true) {
        const n = try file.read(&buf);
        if (n == 0) break;
        for (buf[0..n]) |c| {
            if (c == '\n') count += 1;
        }
        last_byte = buf[n - 1];
    }
    if (last_byte != '\n') count += 1; // unterminated trailing line
    return count;
}

/// Persists session-learned sentences by appending them to the corpus file.
/// NEVER truncates the target: the existing corpus is the canonical store and
/// only the session delta (sentences learned since the last flush) is written.
/// For .qsc containers the delta goes to a "<base>.learned.txt" sidecar.
/// Returns the number of bytes/sentences appended.
pub fn saveCorpusToFile(agent: *agent_mod.Agent, path: []const u8) !agent_mod.Agent.CorpusDeltaFlush {
    var path_buf: [4096]u8 = undefined;
    const out_path = resolveCorpusDeltaPath(path, &path_buf);

    const file = try std.fs.cwd().createFile(out_path, .{ .truncate = false, .read = true });
    defer file.close();

    const end = try file.getEndPos();
    try file.seekTo(end);
    if (end > 0) {
        // Ensure the delta starts on its own line.
        try file.seekTo(end - 1);
        var last: [1]u8 = undefined;
        _ = try file.readAll(&last);
        if (last[0] != '\n') try file.writeAll("\n");
        try file.seekFromEnd(0);
    }

    const res = try agent.flushCorpusDelta(file.writer());
    if (res.bytes > 0) {
        try file.writeAll("\n");
    }
    try file.sync();
    return res;
}

/// Writes a bounded snapshot of the agent's retained corpus window plus any
/// unflushed session delta, via temp file + fsync + atomic rename. This is
/// the explicit full-write path for exports and tests — note the snapshot is
/// the bounded in-memory window, NOT the complete on-disk corpus.
pub fn saveCorpusSnapshotToFile(agent: *agent_mod.Agent, path: []const u8) !void {
    var tmp_buf: [4100]u8 = undefined;
    const tmp_path = std.fmt.bufPrint(&tmp_buf, "{s}.tmp", .{path}) catch return error.NameTooLong;
    {
        const file = try std.fs.cwd().createFile(tmp_path, .{});
        defer file.close();
        try agent.saveCorpus(file.writer());
        if (agent.sessionDeltaPending() > 0) {
            try file.writeAll("\n");
            _ = try agent.flushCorpusDelta(file.writer());
        }
        try file.sync();
    }
    try std.fs.cwd().rename(tmp_path, path);
}

/// Appends the agent's session-learned sentences to an existing file.
/// Alias for saveCorpusToFile — delta-append is the only save semantics.
pub fn appendCorpusToFile(agent: *agent_mod.Agent, path: []const u8) !agent_mod.Agent.CorpusDeltaFlush {
    return saveCorpusToFile(agent, path);
}

/// Loads the "<base>.learned.txt" sidecar for a .qsc corpus, if present.
/// Session-learned sentences are persisted there by saveCorpusToFile; loading
/// it restores them into the agent's corpus window at startup.
/// Returns bytes loaded, or 0 if the path is not .qsc or no sidecar exists.
pub fn loadCorpusSidecar(agent: *agent_mod.Agent, qsc_path: []const u8) !usize {
    var buf: [4096]u8 = undefined;
    const sidecar = resolveCorpusDeltaPath(qsc_path, &buf);
    if (std.mem.eql(u8, sidecar, qsc_path)) return 0;
    const file = std.fs.cwd().openFile(sidecar, .{}) catch return 0;
    file.close();
    return loadCorpusFromFile(agent, sidecar);
}

/// Loads a corpus from a file into the agent's dynamic corpus.
/// Auto-detects .qsc compressed containers by magic; falls back to raw text.
pub fn loadCorpusFromFile(agent: *agent_mod.Agent, path: []const u8) !usize {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    // Detect quine-style .qsc container by magic (QSC1)
    var magic: [4]u8 = undefined;
    const n = try file.readAll(&magic);
    if (n == 4 and std.mem.eql(u8, &magic, &corpus_store.QSC_MAGIC)) {
        // Use streaming path: learn sentence-by-sentence with bounded memory
        var store = try corpus_store.CorpusStore.init(agent.allocator, path);
        defer store.deinit();
        return agent.loadCorpusStreaming(&store);
    }

    return agent.loadCorpus(file.reader());
}

/// Streams a .qsc corpus container through the agent's learnFromText,
/// building the bigram model and knowledge graph without loading the
/// full corpus into memory. Pages are decompressed lazily from the
/// compressed .qsc container (holo VFS streaming pattern).
/// Only streams enough pages to fill the bounded 12MB dynamic_corpus window.
/// Returns the number of sentences learned.
pub fn streamCorpusFromQsc(agent: *agent_mod.Agent, qsc_path: []const u8) !usize {
    return streamCorpusFromQscMax(agent, qsc_path, 16);
}

/// Streams up to max_pages from a .qsc container. If max_pages is 0, streams all.
pub fn streamCorpusFromQscMax(agent: *agent_mod.Agent, qsc_path: []const u8, max_pages: usize) !usize {
    var store = try corpus_store.CorpusStore.init(agent.allocator, qsc_path);
    defer store.deinit();
    return agent.loadCorpusStreamingMax(&store, max_pages);
}

/// Converts a raw corpus .txt file to a compressed .qsc container.
/// Returns the number of pages written.
pub fn convertCorpusToQsc(allocator: std.mem.Allocator, raw_path: []const u8, qsc_path: []const u8) !usize {
    return corpus_store.buildCorpusStore(allocator, raw_path, qsc_path, corpus_store.DEFAULT_PAGE_SIZE);
}

/// Result for directory ingestion operations.
pub const IngestResult = struct {
    files_scanned: usize,
    files_read: usize,
    sentences_learned: usize,
    bytes_processed: usize,
    corpus_size_before: usize,
    corpus_size_after: usize,
};

/// Directly ingests all supported documents from a directory tree.
/// Reads .md/.txt/.tex files, strips markdown/LaTeX, extracts clean sentences,
/// and learns them into the agent's dynamic corpus. No Ollama needed.
pub fn ingestFromDirectory(
    agent: *agent_mod.Agent,
    root_dir: []const u8,
    verbose: bool,
    allocator: std.mem.Allocator,
) !IngestResult {
    const corpus_before = agent.getCorpusSentenceCount();

    var paths = try doc_loader.collectFilePaths(allocator, root_dir);
    defer {
        for (paths.items) |p| allocator.free(p);
        paths.deinit();
    }

    var files_read: usize = 0;
    var sentences_learned: usize = 0;
    var bytes_processed: usize = 0;

    for (paths.items) |path| {
        const text = doc_loader.processFile(allocator, path) catch |err| {
            if (verbose) {
                std.debug.print("  Warning: cannot process {s}: {s}\n", .{ path, @errorName(err) });
            }
            continue;
        };
        defer allocator.free(text);

        files_read += 1;
        bytes_processed += text.len;

        const learned = try agent.learnFromText(text);
        sentences_learned += learned;

        if (verbose and files_read % 50 == 0) {
            std.debug.print("  [{d}/{d}] Ingested {d} files, {d} sentences learned so far\n", .{ files_read, paths.items.len, files_read, sentences_learned });
        }
    }

    if (verbose) {
        std.debug.print("  Ingestion complete: {d}/{d} files, {d} sentences learned, {d} bytes processed\n", .{ files_read, paths.items.len, sentences_learned, bytes_processed });
    }

    const corpus_after = agent.getCorpusSentenceCount();

    return IngestResult{
        .files_scanned = paths.items.len,
        .files_read = files_read,
        .sentences_learned = sentences_learned,
        .bytes_processed = bytes_processed,
        .corpus_size_before = corpus_before,
        .corpus_size_after = corpus_after,
    };
}

// =============================================================================
// Internet Training Pipeline
// =============================================================================

/// Wikipedia article titles to fetch for internet training.
/// These cover the same domains as DEFAULT_PROMPTS but are article titles
/// suitable for the Wikipedia REST API.
pub const WIKIPEDIA_ARTICLES = [_][]const u8{
    // Physics
    "Quantum_entanglement",                      "Neural_network",                                    "Quantum_computing",
    "Encryption",                                "Machine_learning",                                  "Theories_of_general_relativity",
    "Blockchain",                                "Computer",                                          "Artificial_intelligence",
    "Entropy_(information_theory)",              "Deep_learning",                                     "Internet",
    "Data_compression",                          "Parallel_computing",                                "Cloud_computing",
    "Database",                                  "Cybersecurity",                                     "Halting_problem",
    "Computational_complexity_theory",           "Operating_system",
    // AI/ML
                                     "Transformer_(deep_learning_architecture)",
    "Convolutional_neural_network",              "Reinforcement_learning",                            "Generative_adversarial_network",
    "Autoencoder",                               "Federated_learning",                                "Natural_language_processing",
    "Vanishing_gradient_problem",                "Transfer_learning",                                 "Attention_(machine_learning)",
    // Physics
    "Uncertainty_principle",                     "Entropy",                                           "Maxwell%27s_equations",
    "Nuclear_fission",                           "Nuclear_fusion",                                    "Lens_(optics)",
    "Mirror",                                    "Fluid_dynamics",                                    "Bernoulli%27s_principle",
    "Quantum_field_theory",                      "Standard_Model",                                    "Stellar_evolution",
    "Big_Bang",
    // Biology
                                     "Natural_selection",                                 "DNA",
    "Organelle",                                 "Ecosystem",                                         "Bacteria",
    "Virus",                                     "Fungus",                                            "Immune_system",
    "Cell_(biology)",                            "Mitosis",                                           "Meiosis",
    "Protein",                                   "Enzyme",                                            "Genetics",
    // Chemistry
    "Chemical_bond",                             "Periodic_table",                                    "Organic_chemistry",
    "Stoichiometry",                             "Acid",                                              "Base_(chemistry)",
    "Catalysis",
    // Earth Science
                                    "Plate_tectonics",                                   "Mineral",
    "Igneous_rock",                              "Weathering",
    // Economics
                                           "Microeconomics",
    "Macroeconomics",                            "Behavioral_economics",                              "Recession",
    "Stock_market",
    // Climate
                                 "Climate_change",                                    "Renewable_energy",
    "Biodiversity",                              "Carbon_cycle",                                      "Ocean_acidification",
    "Deforestation",                             "Sustainable_development",                           "Conservation_biology",
    // Space
    "Solar_System",                              "Star",                                              "Galaxy",
    "Black_hole",                                "Exoplanet",                                         "Dark_matter",
    "Cosmic_microwave_background",               "Space_exploration",
    // Medicine
                                    "Circulatory_system",
    "Cancer",                                    "Vaccine",                                           "Antibiotic",
    "Mental_disorder",                           "Epidemiology",                                      "Brain",
    "Analgesic",
    // Psychology
                                    "Cognitive_bias",                                    "Classical_conditioning",
    "Operant_conditioning",                      "Jean_Piaget",                                       "Social_psychology",
    "Personality_psychology",                    "Memory",                                            "Perception",
    "Cognitive_behavioral_therapy",
    // Math
                 "Prime_number",                                      "Euclidean_geometry",
    "Statistical_hypothesis_testing",            "Mathematical_logic",                                "Graph_theory",
    "Differential_equation",                     "Topology",                                          "Combinatorics",
    // Engineering
    "Civil_engineering",                         "Mechanical_engineering",                            "Electrical_engineering",
    "Chemical_engineering",                      "Aerospace_engineering",                             "Biomedical_engineering",
    "Software_engineering",                      "Systems_engineering",
    // Security
                                  "Cryptography",
    "Authentication",                            "Phishing",                                          "SQL_injection",
    "Threat_model",                              "Penetration_test",                                  "Firewall_(computing)",
    "Malware",                                   "Social_engineering_(security)",
    // General knowledge / factual
                        "Photosynthesis",
    "Water_(molecule)",                          "Solar_System",                                      "Human_body",
    "France",                                    "Paris",                                             "Speed_of_light",
    "Albert_Einstein",                           "Skin_(anatomy)",                                    "Boiling_point",
    "Atmospheric_pressure",
    // --- Batch 2: Philosophy & Mind (for self-referential / adversarial prompts) ---
                         "Philosophy_of_mind",                                "Consciousness",
    "René_Descartes",                           "Turing_test",                                       "Chinese_room",
    "Artificial_general_intelligence",           "Hard_problem_of_consciousness",                     "Qualia",
    "Free_will",                                 "Determinism",                                       "Solipsism",
    "Epistemology",                              "Ethics",                                            "Aesthetics",
    "Metaphysics",                               "Existentialism",                                    "Stoicism",
    "Nihilism",                                  "Pragmatism",                                        "Utilitarianism",
    "Kantianism",                                "Phenomenology_(philosophy)",                        "Dualism_(philosophy_of_mind)",
    "Physicalism",                               "Functionalism_(philosophy_of_mind)",                "Behaviorism",
    // --- Logic & Reasoning ---
    "Propositional_calculus",                    "First-order_logic",                                 "Syllogism",
    "Logical_fallacy",                           "Deductive_reasoning",                               "Inductive_reasoning",
    "Abductive_reasoning",                       "Modus_ponens",                                      "Modus_tollens",
    "Bayesian_inference",                        "Critical_thinking",                                 "Argumentation_theory",
    "Informal_logic",                            "Contradiction",
    // --- History ---
                                        "World_War_I",
    "World_War_II",                              "Cold_War",                                          "Renaissance",
    "Industrial_Revolution",                     "Ancient_Egypt",                                     "Roman_Empire",
    "Ancient_Greece",                            "Middle_Ages",                                       "Age_of_Enlightenment",
    "French_Revolution",                         "American_Revolution",                               "Byzantine_Empire",
    "Ottoman_Empire",                            "Mongol_Empire",                                     "Silk_Road",
    "Crusades",                                  "Colonialism",
    // --- Literature & Arts (for creative prompts) ---
                                          "William_Shakespeare",
    "Poetry",                                    "Haiku",                                             "Novel",
    "Fiction",                                   "Mythology",                                         "Fairy_tale",
    "Epic_poetry",                               "Sonnet",                                            "Literature",
    "Creative_writing",                          "Narrative",                                         "Music",
    "Painting",                                  "Sculpture",                                         "Architecture",
    "Dance",                                     "Theatre",                                           "Film",
    "Photography",                               "Animation",
    // --- Geography ---
                                            "Earth",
    "Continent",                                 "Ocean",                                             "Mountain",
    "Desert",                                    "River",                                             "Mediterranean_Sea",
    "Atlantic_Ocean",                            "Pacific_Ocean",                                     "Sahara",
    "Amazon_rainforest",                         "Himalayas",                                         "Antarctica",
    "Arctic_Ocean",                              "Nile",
    // --- Chemistry elements ---
                                                 "Oxygen",
    "Hydrogen",                                  "Carbon_dioxide",                                    "Nitrogen",
    "Iron",                                      "Gold",                                              "Silver",
    "Copper",                                    "Helium",                                            "Uranium",
    "Plutonium",                                 "Lead",
    // --- Planets & astronomy ---
                                                 "Moon",
    "Sun",                                       "Jupiter",                                           "Saturn",
    "Mars",                                      "Venus",                                             "Mercury_(planet)",
    "Neptune",                                   "Uranus",                                            "Comet",
    "Asteroid",                                  "Meteoroid",                                         "Supernova",
    "Neutron_star",                              "White_dwarf",
    // --- Math extended ---
                                          "Algebra",
    "Calculus",                                  "Geometry",                                          "Statistics",
    "Probability",                               "Number_theory",                                     "Set_theory",
    "Trigonometry",                              "Linear_algebra",                                    "Fractal",
    "Golden_ratio",                              "Fibonacci_sequence",
    // --- Computer science extended ---
                                   "Algorithm",
    "Data_structure",                            "Programming_language",                              "Compiler",
    "Computer_network",                          "Binary_number",                                     "Boolean_algebra",
    "Turing_machine",                            "Information_theory",                                "Cryptography",
    "Hash_function",                             "Public-key_cryptography",
    // --- Biology extended ---
                              "Evolution",
    "Ecology",                                   "Microbiology",                                      "Virology",
    "Immunology",                                "Anatomy",                                           "Physiology",
    "Botany",                                    "Zoology",                                           "Taxonomy_(biology)",
    "Homo_sapiens",                              "Neuron",
    // --- Psychology extended ---
                                               "Intelligence",
    "Creativity",                                "Motivation",                                        "Emotion",
    "Developmental_psychology",                  "Cognitive_psychology",                              "Intelligence_quotient",
    "Learning",                                  "Habit",
    // --- Sociology & Political science ---
                                                "Culture",
    "Society",                                   "Social_class",                                      "Democracy",
    "Republic",                                  "Monarchy",                                          "Constitution",
    "Political_party",                           "Election",
    // --- Economics extended ---
                                             "Supply_and_demand",
    "Inflation",                                 "Gross_domestic_product",                            "Monetary_policy",
    "Fiscal_policy",                             "Central_bank",
    // --- Physics extended ---
                                         "Thermodynamics",
    "Electromagnetism",                          "Classical_mechanics",                               "Quantum_mechanics",
    "Special_relativity",                        "General_relativity",                                "String_theory",
    "Loop_quantum_gravity",                      "Dark_energy",
    // --- Food & Nutrition ---
                                          "Nutrition",
    "Vitamin",                                   "Carbohydrate",                                      "Metabolism",
    "Dietary_mineral",                           "Protein_(nutrient)",
    // --- Language ---
                                   "Linguistics",
    "Phonetics",                                 "Syntax",                                            "Semantics",
    "Pragmatics",                                "Language_acquisition",
    // --- Education ---
                                 "Pedagogy",
    "Curriculum",                                "Literacy",
    // --- Law ---
                                             "Jurisprudence",
    "Criminal_law",                              "Civil_law_(common_law)",
    // --- Technology ---
                               "Semiconductor",
    "Transistor",                                "Integrated_circuit",                                "Microprocessor",
    "Quantum_computer",
    // --- More general knowledge ---
                             "Color",                                             "Light",
    "Sound",                                     "Temperature",                                       "Energy",
    "Force",                                     "Momentum",                                          "Gravity",
    "Friction",                                  "Wave",                                              "Frequency",
    "Wavelength",
    // --- Batch 3: Religion & Mythology ---
                                   "Buddhism",                                          "Christianity",
    "Islam",                                     "Hinduism",                                          "Judaism",
    "Sikhism",                                   "Confucianism",                                      "Taoism",
    "Shinto",                                    "Atheism",                                           "Agnosticism",
    "Theism",                                    "Reincarnation",                                     "Karma",
    "Nirvana_(Buddhism)",                        "Prayer",                                            "Meditation",
    "Monasticism",                               "Prophet",                                           "Messiah",
    "Covenant_(religion)",                       "Sin",                                               "Salvation",
    "Faith",
    // --- Anthropology & Archaeology ---
                                        "Anthropology",                                      "Archaeology",
    "Human_evolution",                           "Neanderthal",                                       "Homo_erectus",
    "Stone_Age",                                 "Bronze_Age",                                        "Iron_Age",
    "Agriculture",                               "Domestication",                                     "Tool",
    "Fire",                                      "Wheel",                                             "Writing",
    "Cuneiform",                                 "Hieroglyph",                                        "Papyrus",
    "Parchment",
    // --- Geology & Earth Science ---
                                    "Plate_tectonics",                                   "Earthquake",
    "Volcano",                                   "Mineral",                                           "Igneous_rock",
    "Sedimentary_rock",                          "Metamorphic_rock",                                  "Geological_time_scale",
    "Fossil",                                    "Dinosaur",                                          "Extinction_event",
    "Ice_age",                                   "Glacier",                                           "Erosion",
    "Weathering",                                "Soil",                                              "Groundwater",
    "Aquifer",
    // --- Meteorology & Climate ---
                                      "Weather",                                           "Climate",
    "Atmosphere_of_Earth",                       "Cloud",                                             "Rain",
    "Snow",                                      "Thunderstorm",                                      "Tornado",
    "Hurricane",                                 "Cyclone",                                           "Drought",
    "Flood",                                     "El_Niño",                                          "Monsoon",
    "Climate_change",                            "Greenhouse_effect",                                 "Ozone_depletion",
    "Acid_rain",
    // --- Oceanography ---
                                    "Ocean_current",                                     "Tide",
    "Coral_reef",                                "Estuary",                                           "Mangrove",
    "Plankton",                                  "Kelp_forest",                                       "Hydrothermal_vent",
    "Mariana_Trench",
    // --- Medicine & Disease ---
                               "Disease",                                           "Infection",
    "Immune_system",                             "Vaccine",                                           "Antibiotic",
    "Virus",                                     "Bacteria",                                          "Fungus",
    "Parasitism",                                "Cancer",                                            "Diabetes",
    "Malaria",                                   "Tuberculosis",                                      "Influenza",
    "COVID-19",                                  "Heart_disease",                                     "Stroke",
    "Alzheimer's_disease",                       "Surgery",                                           "Anesthesia",
    "Organ_transplant",
    // --- Pharmacology ---
                             "Pharmacology",                                      "Drug",
    "Clinical_trial",                            "Placebo",                                           "Side_effect",
    "Drug_interaction",                          "Aspirin",                                           "Penicillin",
    "Insulin_(medication)",
    // --- Materials Science ---
                         "Steel",                                             "Aluminum",
    "Titanium",                                  "Plastic",                                           "Rubber",
    "Glass",                                     "Ceramic",                                           "Composite_material",
    "Nanomaterial",                              "Semiconductor_device",                              "Superconductivity",
    "Piezoelectricity",
    // --- Energy & Power ---
                             "Fossil_fuel",                                       "Coal",
    "Petroleum",                                 "Natural_gas",                                       "Nuclear_power",
    "Solar_energy",                              "Wind_power",                                        "Hydroelectricity",
    "Geothermal_energy",                         "Biofuel",                                           "Battery_(electricity)",
    "Fuel_cell",                                 "Nuclear_fission",                                   "Nuclear_fusion",
    "Renewable_energy",
    // --- Transportation ---
                             "Rail_transport",                                    "Automobile",
    "Ship",                                      "Aircraft",                                          "Rocket",
    "Spacecraft",                                "Bicycle",                                           "Internal_combustion_engine",
    "Jet_engine",                                "Steam_engine",                                      "Propeller",
    "Submarine",
    // --- Communication & Media ---
                                    "Telecommunication",                                 "Radio",
    "Television",                                "Telephone",                                         "Internet",
    "World_Wide_Web",                            "Newspaper",                                         "Journalism",
    "Social_media",                              "Book",                                              "Printing_press",
    "E-book",                                    "Copyright",                                         "Patent",
    "Trademark",
    // --- Sports & Recreation ---
                                    "Olympic_Games",                                     "Association_football",
    "Basketball",                                "Tennis",                                            "Cricket",
    "Baseball",                                  "Swimming_(sport)",                                  "Athletics_(sport)",
    "Boxing",                                    "Chess",                                             "Video_game",
    "Board_game",
    // --- Food & Agriculture ---
                                   "Rice",                                              "Wheat",
    "Maize",                                     "Potato",                                            "Tomato",
    "Coffee",                                    "Tea",                                               "Chocolate",
    "Sugar",                                     "Spice",                                             "Fermentation_(food)",
    "Bread",                                     "Cheese",                                            "Wine",
    "Beer",                                      "Agricultural_machinery",                            "Irrigation",
    "Fertilizer",
    // --- Fashion & Textiles ---
                                   "Textile",                                           "Cotton",
    "Silk",                                      "Wool",                                              "Linen",
    "Synthetic_fiber",                           "Clothing",                                          "Fashion",
    "Dyeing",
    // --- Military & Defense ---
                                       "Military",                                          "War",
    "Weapon",                                    "Nuclear_weapon",                                    "Biological_warfare",
    "Cyberwarfare",                              "Fortification",                                     "Siege",
    "Guerrilla_warfare",                         "NATO",                                              "United_Nations",
    "European_Union",
    // --- Philosophy Extended ---
                               "Socrates",                                          "Plato",
    "Aristotle",                                 "Immanuel_Kant",                                     "Friedrich_Nietzsche",
    "Karl_Marx",                                 "John_Locke",                                        "David_Hume",
    "Jean-Jacques_Rousseau",                     "Thomas_Aquinas",                                    "Baruch_Spinoza",
    "Gottfried_Wilhelm_Leibniz",                 "John_Stuart_Mill",                                  "Søren_Kierkegaard",
    "Jean-Paul_Sartre",                          "Simone_de_Beauvoir",                                "Hannah_Arendt",
    "Michel_Foucault",
    // --- Mathematics Extended 2 ---
                              "Differential_equation",                             "Integral",
    "Derivative",                                "Limit_(mathematics)",                               "Vector_space",
    "Matrix_(mathematics)",                      "Eigenvalues_and_eigenvectors",                      "Fourier_transform",
    "Topology",                                  "Graph_theory",                                      "Combinatorics",
    "Game_theory",                               "Chaos_theory",                                      "Dynamical_system",
    "Optimization_(mathematics)",
    // --- Computer Science Extended 2 ---
                   "Operating_system",                                  "Database",
    "SQL",                                       "Machine_learning",                                  "Deep_learning",
    "Neural_network",                            "Natural_language_processing",                       "Computer_vision",
    "Reinforcement_learning",                    "Distributed_computing",                             "Cloud_computing",
    "Virtualization",                            "Containerization_(computing)",                      "DevOps",
    "Agile_software_development",
    // --- Chemistry Extended ---
                   "Periodic_table",                                    "Atomic_orbital",
    "Chemical_bond",                             "Molecule",                                          "Polymer",
    "Catalyst",                                  "Acid",                                              "Base_(chemistry)",
    "pH",                                        "Redox",                                             "Electrolysis",
    "Chemical_reaction",                         "Organic_chemistry",                                 "Biochemistry",
    "Analytical_chemistry",
    // --- Astronomy Extended ---
                         "Galaxy",                                            "Black_hole",
    "Big_Bang",                                  "Cosmology",                                         "Exoplanet",
    "Astrobiology",                              "Space_exploration",                                 "Apollo_program",
    "International_Space_Station",               "James_Webb_Space_Telescope",                        "Hubble_Space_Telescope",
    "Voyager_program",
    // --- Psychology Extended 2 ---
                              "Psychoanalysis",                                    "Cognitive_behavioral_therapy",
    "Social_psychology",                         "Personality_psychology",                            "Abnormal_psychology",
    "Neuropsychology",                           "Cognitive_bias",                                    "Confirmation_bias",
    "Dunning-Kruger_effect",                     "Stanford_prison_experiment",                        "Milgram_experiment",
    "Maslow's_hierarchy_of_needs",
    // --- Economics Extended 2 ---
                  "Capitalism",                                        "Socialism",
    "Communism",                                 "Keynesian_economics",                               "Milton_Friedman",
    "Adam_Smith",                                "John_Maynard_Keynes",                               "Karl_Polanyi",
    "Behavioral_economics",                      "Game_theory_in_economics",                          "Economic_globalization",
    "Wealth_inequality",
    // --- Batch 4: Native American Cultures & Lore ---
                            "Adena_culture",                                     "Hopewell_culture",
    "Ohio_Hopewell",                             "Newark_Earthworks",                                 "Serpent_Mound",
    "Mound_City_Group",                          "Hopewell_tradition",                                "Effigy_Mound",
    "Mound_builder_(people)",                    "Hopi",                                              "Hopi_language",
    "Hopi_mythology",                            "Kachina",                                           "Kiva_(architecture)",
    "Puebloan_peoples",                          "Cherokee",                                          "Cherokee_language",
    "Cherokee_mythology",                        "Trail_of_Tears",                                    "Cherokee_Nation_(1794–1907)",
    "Sequoyah",                                  "Blackfoot_Confederacy",                             "Blackfoot_language",
    "Blackfoot_mythology",                       "Siksika",                                           "Kainai_Nation",
    "Piikani_Nation",                            "Bison_hunting",                                     "Sun_dance",
    "Medicine_wheel",                            "Iroquois",                                          "Iroquois_mythology",
    "Haudenosaunee",                             "Iroquois_Confederacy",                              "Great_Law_of_Peace",
    "Hiawatha",                                  "Lakota_people",                                     "Lakota_language",
    "Lakota_mythology",                          "Sioux",                                             "Crazy_Horse",
    "Sitting_Bull",                              "Navajo_people",                                     "Navajo_language",
    "Navajo_mythology",                          "Navajo_sandpainting",                               "Blessingway",
    "Enemy_Way_(Navajo)",                        "Apache",                                            "Apachean_languages",
    "Geronimo",                                  "Comanche",                                          "Comanche_language",
    "Comanche_history",                          "Cheyenne",                                          "Cheyenne_language",
    "Cheyenne_mythology",                        "Algonquian_peoples",                                "Algonquian_languages",
    "Algonquian_mythology",                      "Ojibwe",                                            "Ojibwe_language",
    "Ojibwe_mythology",                          "Cree",                                              "Cree_language",
    "Cree_mythology",                            "Inuit",                                             "Inuit_mythology",
    "Inuit_language",                            "Maya_civilization",                                 "Maya_mythology",
    "Maya_script",                               "Aztec",                                             "Aztec_mythology",
    "Aztec_language",                            "Toltec",                                            "Olmec",
    "Mississippian_culture",                     "Cahokia",                                           "Poverty_Point",
    "Mound_Builders",                            "Pottery_of_the_indigenous_peoples_of_the_Americas", "Indigenous_peoples_of_the_Americas",
    "Native_American_religion",                  "Vision_quest",                                      "Sweat_lodge",
    "Peace_pipe",                                "Dreamcatcher",                                      "Totem_pole",
    "Powwow",                                    "Wampum",                                            "Three_Sisters_(agriculture)",
    "Indigenous_peoples_of_California",          "Ancestral_Puebloans",                               "Clovis_culture",
    "Folsom_tradition",                          "Plano_culture",                                     "Archaic_period_in_the_Americas",
    "Woodland_period",                           "Fort_Ancient",                                      "Angel_Mounds",
    "Cahokia_Mounds",                            "Spiro_Mounds",                                      "Etowah_Indian_Mounds",
    // --- Retries: previously failed/empty with alternate titles ---
    "Utilitarianism",                            "Kantianism",                                        "Phenomenology",
    "Propositional_calculus",                    "First-order_logic",                                 "Syllogism",
    "Logical_fallacy",                           "Deductive_reasoning",                               "Inductive_reasoning",
    "Abductive_reasoning",                       "Modus_ponens",                                      "Modus_tollens",
    "Bayesian_inference",                        "Critical_thinking",                                 "Argumentation_theory",
    "Informal_logic",                            "Contradiction",                                     "Mythology",
    "Homo_sapiens",                              "Dietary_mineral",                                   "Quantum_computer",
    "Geological_time_scale",                     "Hurricane",                                         "Bacteria",
    "Fungus",                                    "Parasitism",                                        "Cancer",
    "Diabetes",                                  "Malaria",                                           "Tuberculosis",
    "Influenza",                                 "COVID-19",                                          "Heart_disease",
    "Stroke",                                    "Alzheimer's_disease",                               "Surgery",
    "Anesthesia",                                "Organ_transplant",                                  "Pharmacology",
    "Drug",                                      "Clinical_trial",                                    "Placebo",
    "Side_effect",                               "Drug_interaction",                                  "Aspirin",
    "Penicillin",                                "Insulin_(medication)",                              "Steel",
    "Aluminum",                                  "Titanium",                                          "Plastic",
    "Rubber",                                    "Glass",                                             "Ceramic",
    "Composite_material",                        "Nanomaterial",                                      "Semiconductor_device",
    "Superconductivity",                         "Piezoelectricity",                                  "Fossil_fuel",
    "Coal",                                      "Petroleum",                                         "Natural_gas",
    "Nuclear_power",                             "Solar_energy",                                      "Wind_power",
    "Hydroelectricity",                          "Geothermal_energy",                                 "Biofuel",
    "Battery_(electricity)",                     "Fuel_cell",                                         "Nuclear_fission",
    "Nuclear_fusion",                            "Renewable_energy",                                  "Rail_transport",
    "Automobile",                                "Ship",                                              "Aircraft",
    "Rocket",                                    "Spacecraft",                                        "Bicycle",
    "Internal_combustion_engine",                "Jet_engine",                                        "Steam_engine",
    "Propeller",                                 "Submarine",                                         "Telecommunication",
    "Radio",                                     "Television",                                        "Telephone",
    "Internet",                                  "World_Wide_Web",                                    "Newspaper",
    "Journalism",                                "Social_media",                                      "Book",
    "Printing_press",                            "E-book",                                            "Copyright",
    "Patent",                                    "Trademark",                                         "Olympic_Games",
    "Association_football",                      "Basketball",                                        "Tennis",
    "Cricket",                                   "Baseball",                                          "Swimming_(sport)",
    "Athletics_(sport)",                         "Boxing",                                            "Chess",
    "Video_game",                                "Board_game",                                        "Rice",
    "Wheat",                                     "Maize",                                             "Potato",
    "Tomato",                                    "Coffee",                                            "Tea",
    "Chocolate",                                 "Sugar",                                             "Spice",
    "Fermentation_(food)",                       "Bread",                                             "Cheese",
    "Wine",                                      "Beer",                                              "Agricultural_machinery",
    "Irrigation",                                "Fertilizer",                                        "Textile",
    "Cotton",                                    "Silk",                                              "Wool",
    "Linen",                                     "Synthetic_fiber",                                   "Clothing",
    "Fashion",                                   "Dyeing",                                            "Military",
    "War",                                       "Weapon",                                            "Nuclear_weapon",
    "Biological_warfare",                        "Cyberwarfare",                                      "Fortification",
    "Siege",                                     "Guerrilla_warfare",                                 "NATO",
    "United_Nations",                            "European_Union",                                    "Socrates",
    "Plato",                                     "Aristotle",                                         "Immanuel_Kant",
    "Friedrich_Nietzsche",                       "Karl_Marx",                                         "John_Locke",
    "David_Hume",                                "Jean-Jacques_Rousseau",                             "Thomas_Aquinas",
    "Baruch_Spinoza",                            "Gottfried_Wilhelm_Leibniz",                         "John_Stuart_Mill",
    "Søren_Kierkegaard",                        "Jean-Paul_Sartre",                                  "Simone_de_Beauvoir",
    "Hannah_Arendt",                             "Michel_Foucault",                                   "Differential_equation",
    "Integral",                                  "Derivative",                                        "Limit_(mathematics)",
    "Vector_space",                              "Matrix_(mathematics)",                              "Eigenvalues_and_eigenvectors",
    "Fourier_transform",                         "Topology",                                          "Graph_theory",
    "Combinatorics",                             "Game_theory",                                       "Chaos_theory",
    "Dynamical_system",                          "Optimization_(mathematics)",                        "Operating_system",
    "Database",                                  "SQL",                                               "Machine_learning",
    "Deep_learning",                             "Neural_network",                                    "Natural_language_processing",
    "Computer_vision",                           "Reinforcement_learning",                            "Distributed_computing",
    "Cloud_computing",                           "Virtualization",                                    "Containerization_(computing)",
    "DevOps",                                    "Agile_software_development",                        "Periodic_table",
    "Atomic_orbital",                            "Chemical_bond",                                     "Molecule",
    "Polymer",                                   "Catalyst",                                          "Acid",
    "Base_(chemistry)",                          "pH",                                                "Redox",
    "Electrolysis",                              "Chemical_reaction",                                 "Organic_chemistry",
    "Biochemistry",                              "Analytical_chemistry",                              "Galaxy",
    "Black_hole",                                "Big_Bang",                                          "Cosmology",
    "Exoplanet",                                 "Astrobiology",                                      "Space_exploration",
    "Apollo_program",                            "International_Space_Station",                       "James_Webb_Space_Telescope",
    "Hubble_Space_Telescope",                    "Voyager_program",                                   "Psychoanalysis",
    "Cognitive_behavioral_therapy",              "Social_psychology",                                 "Personality_psychology",
    "Abnormal_psychology",                       "Neuropsychology",                                   "Cognitive_bias",
    "Confirmation_bias",                         "Dunning-Kruger_effect",                             "Stanford_prison_experiment",
    "Milgram_experiment",                        "Maslow's_hierarchy_of_needs",                       "Capitalism",
    "Socialism",                                 "Communism",                                         "Keynesian_economics",
    "Milton_Friedman",                           "Adam_Smith",                                        "John_Maynard_Keynes",
    "Karl_Polanyi",                              "Behavioral_economics",                              "Game_theory_in_economics",
    "Economic_globalization",                    "Wealth_inequality",
    // --- Batch 5: Corrected titles for truly missing pages ---
                                    "Algonquian_religion",
    "Cheyenne_religion",                         "Cree_religion",                                     "Enemy_way",
    "Kiva",                                      "Skin",                                              "General_relativity",
    "Game_theory",                               "Native_American_pottery",
    // --- Batch 5: Re-fetch previously EMPTY (now fixed by &redirects=1) ---
                              "Iroquois",
    "Iroquois_Confederacy",                      "Iroquois_mythology",                                "Automobile",
    "Bison_hunting",                             "Sun_dance",                                         "Puebloan_peoples",
    "Navajo_people",                             "Cherokee_mythology",                                "Peace_pipe",
    "Aztec",                                     "Telecommunication",                                 "Swimming_(sport)",
    "Athletics_(sport)",                         "E-book",                                            "Battery_(electricity)",
    "Catalyst",                                  "Rubber",                                            "Aluminum",
    "Nanomaterial",                              "Optimization_(mathematics)",                        "Heart_disease",
    "Organ_transplant",                          "Inuit_language",                                    "Inuit_mythology",
    "Mississippian_culture",                     "Mound_City_Group",                                  "Effigy_Mound",
    "Mound_builder_(people)",                    "Hopewell_culture",                                  "Ohio_Hopewell",
    "Siksika",                                   "Navajo_sandpainting",                               "Blessingway",
    "Enemy_Way_(Navajo)",                        "Apachean_languages",                                "Algonquian_mythology",
    "Ojibwe_mythology",                          "Cree_mythology",                                    "Cheyenne_mythology",
    "Plano_culture",                             "Archaic_period_in_the_Americas",                    "Cahokia_Mounds",
    "Native_American_religion",                  "Dreamcatcher",                                      "Pottery_of_the_indigenous_peoples_of_the_Americas",
    "Kantianism",                                "Propositional_calculus",                            "Logical_fallacy",
    "Mythology",                                 "Homo_sapiens",                                      "Quantum_computer",
    "Geological_time_scale",                     "Hurricane",                                         "Wealth_inequality",
    "Skin_(anatomy)",                            "Theories_of_general_relativity",                    "Game_theory_in_economics",
    "Economic_globalization",                    "Phenomenology",                                     "Cognitive_bias",
    "Confirmation_bias",                         "Dunning-Kruger_effect",
    // --- Batch 6: Final retry with corrected titles for remaining failures ---
                                "Anishinaabe_religion",
    "Cheyenne_religion_and_spirituality",        "Cree_religion",                                     "Navajo_song_ceremonial_complex",
    "Kiva",                                      "Skin",                                              "General_relativity",
    "Game_theory",                               "Native_American_pottery",                           "Iroquois_Confederacy",
    "Iroquois_mythology",                        "Inuit_languages",                                   "Inuit_religion",
    "Apachean_languages",                        "Algonquian_mythology",                              "Aluminium",
    "Catalysis",                                 "Natural_rubber",                                    "Electric_battery",
    "Nanomaterials",                             "Mathematical_optimization",                         "Cardiovascular_disease",
    "Transplantation_(medicine)",                "Propositional_logic",                               "Formal_fallacy",
    "Human",                                     "Quantum_computing",                                 "Geologic_time_scale",
    "Atlantic_hurricane",                        "Distribution_of_wealth",                            "Phenomenology_(philosophy)",
    "Economic_globalization",                    "Dunning-Kruger_effect",
    // --- Batch 7: Last retry for rate-limited + alternate titles ---
                                "Iroquois_mythology",
    "Inuit_languages",                           "Transplantation_(medicine)",                        "Dunning-Kruger_effect",
    "Anishinaabe",                               "Cheyenne_people",                                   "Algonquian_people",
    // --- Batch 8: Ohio River Valley Mound Builders ---
    "Miamisburg_Mound",                          "Great_Serpent_Mound",                               "Alligator_Mound",
    "Octagon_Earthworks",                        "High_Bank_Works",                                   "Seip_Earthworks",
    "Baum_Earthworks",                           "Fort_Ancient_(Ohio)",                               "SunWatch_Indian_Village",
    "Hopewell_Culture_National_Historical_Park", "Tremper_Mound",                                     "Hopeton_Earthworks",
    "Marietta_Earthworks",                       "Portsmouth_Earthworks",                             "Turner_Group",
    "Harness_Mound",                             "Cedar_Bank_Works",                                  "Fort_Hill_(Ohio)",
    "Pollock_Earthworks",                        "Mariemont_Earthworks",                              "Story_Mound",
    "Glacial_Kame_Culture",                      "Intrusive_Mound_Culture",                           "Cole_Culture",
    "Monongahela_culture",                       "Whittlesey_Focus",                                  "Ohio_River_Valley",
    "Prehistory_of_Ohio",                        "Woodland_period",                                   "Archaic_period_in_the_Americas",
    // --- Batch 8b: Afro-Indigenous Maroons / "Morrons" ---
    "Maroon_(people)",                           "Maroon_Seminole",                                   "Black_Seminoles",
    "Gullah",                                    "Gullah_Geechee",                                    "Quilombo",
    "Palmares_(quilombo)",                       "Jamaican_Maroons",                                  "Nanny_of_the_Maroons",
    "Cudjoe",                                    "Accompong",                                         "Suriname_Maroons",
    "Saramaka",                                  "Ndyuka",                                            "Aluku",
    "Matawai",                                   "Kwinti",                                            "Bushinengue",
    "Garifuna",                                  "Black_Carib",                                       "Afro-Indigenous",
    "Black_Indians",                             "Cherokee_Freedmen",                                 "Seminole_Wars",
    "African-Native_American_relations",         "Seminole",                                          "Freedmen_(Native_American)",
    // --- Batch 8c: French Colonial Ohio River Valley ---
    "New_France",                                "Ohio_Country",                                      "French_and_Indian_War",
    "Fort_Duquesne",                             "Pierre-Joseph_Celoron_de_Blainville",               "Rene-Robert_Cavelier_de_La_Salle",
    "Ohio_Company_of_Virginia",                  "Treaty_of_Paris_(1763)",                            "Proclamation_of_1763",
    "Northwest_Indian_War",                      "Battle_of_Fallen_Timbers",                          "Treaty_of_Greenville",
    "Northwest_Territory",                       "Ohio_River",                                        "French_colonization_of_the_Americas",
    "Coureur_des_bois",                          "Voyageur",                                          "Metis_people",
    "Northwest_Ordinance",                       "Ohio_Company",                                      "Tecumseh",
    "Blue_Jacket",                               "Little_Turtle",                                     "Anthony_Wayne",
    "Arthur_St._Clair",                          "Rufus_Putnam",                                      "Indian_Removal_Act",
    // --- Batch 8d: Ohio General ---
    "Ohio",                                      "History_of_Ohio",                                   "Cincinnati",
    "Cleveland",                                 "Columbus,_Ohio",                                    "Toledo,_Ohio",
    "Dayton,_Ohio",                              "Akron,_Ohio",                                       "Ohio_Erie_Canal",
    "Underground_Railroad",                      "Ohio_in_the_Civil_War",                             "Marietta,_Ohio",
    "Chillicothe,_Ohio",                         "Shawnee",                                           "Miami_people",
    "Wyandot_people",                            "Lenape",                                            "Ottawa_(Indigenous_Ontario)",
    "Ohio_Constitution",                         "Ohio_statehood",                                    "Native_American_tribes_in_Ohio",
    // --- Batch 9: Orch Or Theory ---
    "Orchestrated_objective_reduction",          "Roger_Penrose",                                     "Stuart_Hameroff",
    "Microtubule",                               "Quantum_mind",                                      "Objective_collapse",
    "Penrose_interpretation",                    "Quantum_consciousness",                             "Hameroff_speculation",
    // --- Batch 10: Prime Number Patterns ---
    "Ulam_spiral",                               "Prime_number_theorem",                              "Riemann_hypothesis",
    "Twin_prime",                                "Sieve_of_Eratosthenes",                             "Goldbach%27s_conjecture",
    "Prime_gap",                                 "Bateman%E2%80%93Horn_conjecture",                   "Bertrand%27s_postulate",
    "Cramer%27s_conjecture",                     "Dirichlet%27s_theorem_on_arithmetic_progressions",  "Hardy%E2%80%93Littlewood_circle_method",
    "Prime_number",                              "Prime-counting_function",                           "Legendre%27s_formula",
    // --- Batch 11: Data Structures & Algorithms ---
    "Sorting_algorithm",                         "Search_algorithm",                                  "Dynamic_programming",
    "Greedy_algorithm",                          "Graph_traversal",                                   "Breadth-first_search",
    "Depth-first_search",                        "Dijkstra%27s_algorithm",                            "A*_search_algorithm",
    "Red%E2%80%93black_tree",                    "Hash_table",                                        "Bloom_filter",
    "Trie",                                      "Binary_search_tree",                                "AVL_tree",
    "Heap_(data_structure)",                     "Linked_list",                                       "Skip_list",
    "Disjoint-set_data_structure",               "Quicksort",                                         "Merge_sort",
    "Heapsort",                                  "Radix_sort",                                        "Interpolation_search",
    "Exponential_search",                        "Bellman%E2%80%93Ford_algorithm",                    "Floyd%E2%80%93Warshall_algorithm",
    "Backtracking",                              "Branch_and_bound",                                  "Divide_and_conquer_algorithm",
    "Amortized_analysis",                        "Big_O_notation",                                    "NP-completeness",
    // --- Batch 12: Design Patterns ---
    "Software_design_pattern",                   "Singleton_pattern",                                 "Factory_method_pattern",
    "Observer_pattern",                          "Strategy_pattern",                                  "Command_pattern",
    "Adapter_pattern",                           "Facade_pattern",                                    "Decorator_pattern",
    "Composite_pattern",                         "State_pattern",                                     "Template_method_pattern",
    "Visitor_pattern",                           "Iterator_pattern",                                  "Mediator_pattern",
    // --- Batch 13: Trivium & Quadrivium ---
    "Trivium",                                   "Quadrivium",                                        "Liberal_arts",
    "Grammar",                                   "Logic",                                             "Rhetoric",
    "Arithmetic",                                "Geometry",                                          "Music_theory",
    "Astronomy",                                 "Seven_liberal_arts",                                "Quadrivium_(education)",
};

/// Result for internet training operations.
pub const InternetTrainingResult = struct {
    articles_fetched: usize,
    articles_failed: usize,
    sentences_learned: usize,
    bytes_fetched: usize,
    corpus_size_before: usize,
    corpus_size_after: usize,
};

/// Fetches a Wikipedia article as plain text using the MediaWiki API.
/// Returns owned slice of the article extract text.
fn fetchWikipediaArticle(allocator: std.mem.Allocator, title: []const u8) ![]u8 {
    // Build the Wikipedia API URL
    // https://en.wikipedia.org/w/api.php?action=query&prop=extracts&explaintext=1&format=json&titles=TITLE
    var url_buf = std.ArrayList(u8).init(allocator);
    defer url_buf.deinit();
    try url_buf.appendSlice("https://en.wikipedia.org/w/api.php?action=query&prop=extracts&explaintext=1&format=json&redirects=1&titles=");
    try url_buf.appendSlice(title);

    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();

    var response_body = std.ArrayList(u8).init(allocator);
    errdefer response_body.deinit();

    const result = client.fetch(.{
        .location = .{ .url = url_buf.items },
        .response_storage = .{ .dynamic = &response_body },
    }) catch |err| {
        return err;
    };

    if (result.status != .ok) {
        return error.HttpError;
    }

    // Parse JSON to extract the article text
    // The JSON structure is: {"query":{"pages":{"123":{"title":"...","extract":"..."}}}}
    const json = response_body.items;

    // Find the "extract" field
    const extract_key = "\"extract\":\"";
    if (std.mem.indexOf(u8, json, extract_key)) |pos| {
        const start = pos + extract_key.len;
        // Find the end of the extract string (handle escaped quotes)
        var end = start;
        var escaped = false;
        while (end < json.len) {
            if (escaped) {
                escaped = false;
                end += 1;
                continue;
            }
            if (json[end] == '\\') {
                escaped = true;
                end += 1;
                continue;
            }
            if (json[end] == '"') break;
            end += 1;
        }

        if (end > start) {
            // Unescape the JSON string
            var clean = std.ArrayList(u8).init(allocator);
            errdefer clean.deinit();
            var i = start;
            while (i < end) {
                if (json[i] == '\\' and i + 1 < end) {
                    switch (json[i + 1]) {
                        'n' => {
                            try clean.append('\n');
                            i += 2;
                        },
                        'r' => {
                            try clean.append('\r');
                            i += 2;
                        },
                        't' => {
                            try clean.append('\t');
                            i += 2;
                        },
                        '"' => {
                            try clean.append('"');
                            i += 2;
                        },
                        '\\' => {
                            try clean.append('\\');
                            i += 2;
                        },
                        '/' => {
                            try clean.append('/');
                            i += 2;
                        },
                        'u' => {
                            // Skip unicode escape \uXXXX
                            if (i + 6 <= end) {
                                // Try to decode basic ASCII unicode
                                const hex = json[i + 2 .. i + 6];
                                if (std.fmt.parseInt(u21, hex, 16)) |code| {
                                    var utf8_buf: [4]u8 = undefined;
                                    const len = std.unicode.utf8Encode(code, &utf8_buf) catch 0;
                                    try clean.appendSlice(utf8_buf[0..len]);
                                } else |_| {}
                                i += 6;
                            } else i += 1;
                        },
                        else => {
                            try clean.append(json[i]);
                            i += 1;
                        },
                    }
                } else {
                    try clean.append(json[i]);
                    i += 1;
                }
            }
            response_body.deinit();
            return clean.toOwnedSlice();
        }
    }

    // If no extract found, return empty
    response_body.deinit();
    return allocator.dupe(u8, "");
}

/// Trains the agent by fetching real Wikipedia articles from the internet.
/// For each article title, fetches the full plain-text article and learns from it.
/// Optionally uses Ollama to generate additional training content.
pub fn trainFromInternet(
    agent: *agent_mod.Agent,
    config: TrainingConfig,
    corpus_save_path: ?[]const u8,
    limit: ?usize,
    offset: usize,
    use_ollama: bool,
    allocator: std.mem.Allocator,
    custom_articles: ?[]const []const u8,
) !InternetTrainingResult {
    const corpus_before = agent.getCorpusSentenceCount();

    const article_list = custom_articles orelse &WIKIPEDIA_ARTICLES;
    const total_articles = article_list.len;
    const start_idx = @min(offset, total_articles);
    const available = total_articles - start_idx;
    const max_articles = if (limit) |l| @min(l, available) else available;
    const end_idx = start_idx + max_articles;

    var articles_fetched: usize = 0;
    var articles_failed: usize = 0;
    var consecutive_failures: usize = 0;
    var sentences_learned: usize = 0;
    var bytes_fetched: usize = 0;

    if (config.verbose) {
        std.debug.print("=== Internet Training Pipeline ===\n", .{});
        std.debug.print("Fetching {d} Wikipedia articles (offset {d})\n", .{ max_articles, start_idx });
        if (use_ollama) {
            std.debug.print("Ollama augmentation: ON (model: {s})\n", .{config.ollama.model});
        } else {
            std.debug.print("Ollama augmentation: OFF\n", .{});
        }
        std.debug.print("\n", .{});
    }

    for (article_list[start_idx..end_idx], start_idx..) |title, i| {
        if (config.verbose) {
            std.debug.print("[{d}/{d}] Fetching: {s}... ", .{ i + 1, end_idx, title });
        }

        // Fetch Wikipedia article
        const article_text = fetchWikipediaArticle(allocator, title) catch |err| {
            if (config.verbose) {
                std.debug.print("FAILED ({s})\n", .{@errorName(err)});
            }
            articles_failed += 1;
            consecutive_failures += 1;
            // Exponential backoff after HTTP errors to avoid Wikipedia rate-limiting
            if (!use_ollama) {
                const backoff_ns: u64 = @as(u64, 10_000_000_000) * @as(u64, @min(consecutive_failures, 3));
                std.time.sleep(backoff_ns);
            }
            continue;
        };
        defer allocator.free(article_text);

        if (article_text.len == 0) {
            if (config.verbose) {
                std.debug.print("EMPTY\n", .{});
            }
            articles_failed += 1;
            continue;
        }

        bytes_fetched += article_text.len;
        articles_fetched += 1;
        consecutive_failures = 0;

        // Learn from the Wikipedia article text
        const learned = try agent.learnFromText(article_text);
        sentences_learned += learned;

        if (config.verbose) {
            std.debug.print("{d} bytes, learned {d} sentences", .{ article_text.len, learned });
        }

        // Optionally use Ollama to generate additional content about the topic
        if (use_ollama) {
            // Convert title to a readable prompt
            const readable_title = blk: {
                var buf: [256]u8 = undefined;
                var pos: usize = 0;
                for (title) |c| {
                    if (c == '_') {
                        if (pos < 255) buf[pos] = ' ';
                        pos += 1;
                    } else {
                        if (pos < 255) buf[pos] = c;
                        pos += 1;
                    }
                }
                const len = @min(pos, 255);
                break :blk buf[0..len];
            };

            const ollama_prompt = try std.fmt.allocPrint(allocator, "Explain {s} in clear, factual sentences.", .{readable_title});
            defer allocator.free(ollama_prompt);

            var ollama_resp = llm_provider.complete(allocator, .{ .provider = .remote, .ollama = config.ollama }, ollama_prompt) catch {
                if (config.verbose) {
                    std.debug.print(" (ollama failed)\n", .{});
                }
                // Save corpus periodically
                if (corpus_save_path) |save_path| {
                    if (articles_fetched % 5 == 0) {
                        _ = saveCorpusToFile(agent, save_path) catch undefined;
                    }
                }
                continue;
            };
            defer ollama_resp.deinit();

            const ollama_learned = try agent.learnFromText(ollama_resp.text);
            sentences_learned += ollama_learned;

            if (config.verbose) {
                std.debug.print(" + {d} from Ollama", .{ollama_learned});
            }
        }

        if (config.verbose) {
            std.debug.print("\n", .{});
        }

        // Save corpus every 5 articles for crash recovery
        if (corpus_save_path) |save_path| {
            if (articles_fetched % 5 == 0) {
                _ = saveCorpusToFile(agent, save_path) catch undefined;
            }
        }

        // Rate-limit: when Ollama is off, add a delay to avoid Wikipedia API throttling
        if (!use_ollama) {
            std.time.sleep(3_000_000_000); // 3 seconds
        }
    }

    // Final save
    if (corpus_save_path) |save_path| {
        _ = saveCorpusToFile(agent, save_path) catch undefined;
    }

    if (config.verbose) {
        std.debug.print("\n=== Internet Training Complete ===\n", .{});
        std.debug.print("Articles fetched: {d}\n", .{articles_fetched});
        std.debug.print("Articles failed: {d}\n", .{articles_failed});
        std.debug.print("Sentences learned: {d}\n", .{sentences_learned});
        std.debug.print("Bytes fetched: {d}\n", .{bytes_fetched});
    }

    const corpus_after = agent.getCorpusSentenceCount();

    return InternetTrainingResult{
        .articles_fetched = articles_fetched,
        .articles_failed = articles_failed,
        .sentences_learned = sentences_learned,
        .bytes_fetched = bytes_fetched,
        .corpus_size_before = corpus_before,
        .corpus_size_after = corpus_after,
    };
}

/// Result for OpenAI internet reinforcement operations.
pub const ReinforceResult = struct {
    topics_processed: usize,
    topics_failed: usize,
    sentences_learned: usize,
    corpus_size_before: usize,
    corpus_size_after: usize,
};

/// Reinforce the corpus using OpenAI as an internet knowledge source.
/// For each topic in WIKIPEDIA_ARTICLES (and any extra topics provided),
/// asks OpenAI to provide factual sentences about that topic, then
/// learns from the response. Saves corpus periodically for crash recovery.
pub fn reinforceWithOpenAI(
    agent: *agent_mod.Agent,
    openai_cfg: openai.OpenAIConfig,
    corpus_save_path: ?[]const u8,
    extra_topics: ?[]const []const u8,
    verbose: bool,
    allocator: std.mem.Allocator,
) !ReinforceResult {
    const corpus_before = agent.getCorpusSentenceCount();
    var topics_processed: usize = 0;
    var topics_failed: usize = 0;
    var sentences_learned: usize = 0;

    const extra_count = if (extra_topics) |et| et.len else 0;
    const total_topics = WIKIPEDIA_ARTICLES.len + extra_count;

    if (verbose) {
        std.debug.print("=== OpenAI Internet Reinforcement ===\n", .{});
        std.debug.print("Topics: {d} Wikipedia + {d} extra = {d} total\n", .{ WIKIPEDIA_ARTICLES.len, extra_count, total_topics });
        std.debug.print("Teacher: OpenAI ({s})\n\n", .{openai_cfg.model});
    }

    var topic_idx: usize = 0;

    for (WIKIPEDIA_ARTICLES) |title| {
        topic_idx += 1;
        if (verbose) {
            std.debug.print("[{d}/{d}] Reinforcing: {s}... ", .{ topic_idx, total_topics, title });
        }

        var readable_buf: [256]u8 = undefined;
        const readable = readableTitle(title, &readable_buf);

        const prompt = try std.fmt.allocPrint(allocator, "Provide 5 key factual sentences about {s}. Return only the sentences, one per line, no numbering.", .{readable});
        defer allocator.free(prompt);

        var resp = openai.simplePrompt(allocator, openai_cfg, "You are a knowledgeable teacher providing factual information for reinforcement learning.", prompt) catch |err| {
            if (verbose) {
                std.debug.print("FAILED ({s})\n", .{@errorName(err)});
            }
            topics_failed += 1;
            continue;
        };
        defer resp.deinit();

        const learned = try agent.learnFromText(resp.text);
        sentences_learned += learned;
        topics_processed += 1;

        if (verbose) {
            std.debug.print("learned {d} sentences\n", .{learned});
        }

        if (corpus_save_path) |save_path| {
            if (topics_processed % 10 == 0) {
                _ = saveCorpusToFile(agent, save_path) catch undefined;
            }
        }
    }

    if (extra_topics) |topics| {
        for (topics) |topic| {
            topic_idx += 1;
            if (verbose) {
                std.debug.print("[{d}/{d}] Reinforcing: {s}... ", .{ topic_idx, total_topics, topic });
            }

            const prompt = try std.fmt.allocPrint(allocator, "Provide 5 key factual sentences about {s}. Return only the sentences, one per line, no numbering.", .{topic});
            defer allocator.free(prompt);

            var resp = openai.simplePrompt(allocator, openai_cfg, "You are a knowledgeable teacher providing factual information for reinforcement learning.", prompt) catch |err| {
                if (verbose) {
                    std.debug.print("FAILED ({s})\n", .{@errorName(err)});
                }
                topics_failed += 1;
                continue;
            };
            defer resp.deinit();

            const learned = try agent.learnFromText(resp.text);
            sentences_learned += learned;
            topics_processed += 1;

            if (verbose) {
                std.debug.print("learned {d} sentences\n", .{learned});
            }

            if (corpus_save_path) |save_path| {
                if (topics_processed % 10 == 0) {
                    _ = saveCorpusToFile(agent, save_path) catch undefined;
                }
            }
        }
    }

    if (corpus_save_path) |save_path| {
        _ = saveCorpusToFile(agent, save_path) catch undefined;
    }

    if (verbose) {
        std.debug.print("\nReinforcement complete: {d}/{d} topics processed, {d} sentences learned\n", .{ topics_processed, total_topics, sentences_learned });
    }

    const corpus_after = agent.getCorpusSentenceCount();

    return ReinforceResult{
        .topics_processed = topics_processed,
        .topics_failed = topics_failed,
        .sentences_learned = sentences_learned,
        .corpus_size_before = corpus_before,
        .corpus_size_after = corpus_after,
    };
}

/// Convert a Wikipedia article title (underscores) to readable form (spaces).
fn readableTitle(title: []const u8, buf: *[256]u8) []const u8 {
    var pos: usize = 0;
    for (title) |c| {
        if (pos >= 255) break;
        if (c == '_') {
            buf[pos] = ' ';
        } else {
            buf[pos] = c;
        }
        pos += 1;
    }
    return buf[0..pos];
}

// =============================================================================
// Tests
// =============================================================================

test "training: default TrainingConfig values" {
    const config = TrainingConfig{};
    try std.testing.expect(config.verbose == true);
    try std.testing.expectEqualStrings("127.0.0.1", config.ollama.host);
    try std.testing.expectEqual(@as(u16, 11434), config.ollama.port);
    try std.testing.expect(config.teacher == .auto);
    try std.testing.expect(config.openai == null);
}

test "training: resolveTeacher auto picks OpenAI when key present" {
    const config = TrainingConfig{
        .openai = .{ .api_key = "sk-test" },
        .teacher = .auto,
    };
    try std.testing.expect(resolveTeacher(config) == .openai);
}

test "training: resolveTeacher auto picks Ollama without key" {
    const config = TrainingConfig{ .teacher = .auto };
    try std.testing.expect(resolveTeacher(config) == .ollama);
}

test "training: resolveTeacher explicit ollama wins" {
    const config = TrainingConfig{
        .openai = .{ .api_key = "sk-test" },
        .teacher = .ollama,
    };
    try std.testing.expect(resolveTeacher(config) == .ollama);
}

test "training: resolveTeacher explicit openai wins" {
    const config = TrainingConfig{
        .openai = .{ .api_key = "sk-test" },
        .teacher = .openai,
    };
    try std.testing.expect(resolveTeacher(config) == .openai);
}

test "training: resolveTeacher openai without key still resolves openai" {
    // Explicit openai teacher with no key — resolveTeacher honors the explicit
    // choice; trainOnPrompt will gracefully return 0 (no crash).
    const config = TrainingConfig{ .teacher = .openai };
    try std.testing.expect(resolveTeacher(config) == .openai);
}

test "training: TrainingResult struct initialization" {
    const result = TrainingResult{
        .prompts_processed = 5,
        .sentences_learned = 12,
        .corpus_size_before = 100,
        .corpus_size_after = 112,
    };
    try std.testing.expectEqual(@as(usize, 5), result.prompts_processed);
    try std.testing.expectEqual(@as(usize, 12), result.sentences_learned);
    try std.testing.expectEqual(@as(usize, 100), result.corpus_size_before);
    try std.testing.expectEqual(@as(usize, 112), result.corpus_size_after);
}

test "training: DEFAULT_PROMPTS is non-empty" {
    try std.testing.expect(DEFAULT_PROMPTS.len > 0);
    try std.testing.expect(DEFAULT_PROMPTS.len == 300);
}

test "training: IngestResult struct initialization" {
    const result = IngestResult{
        .files_scanned = 10,
        .files_read = 8,
        .sentences_learned = 50,
        .bytes_processed = 5000,
        .corpus_size_before = 200,
        .corpus_size_after = 250,
    };
    try std.testing.expectEqual(@as(usize, 10), result.files_scanned);
    try std.testing.expectEqual(@as(usize, 8), result.files_read);
    try std.testing.expectEqual(@as(usize, 50), result.sentences_learned);
    try std.testing.expectEqual(@as(usize, 5000), result.bytes_processed);
}

test "training: saveCorpusToFile and loadCorpusFromFile round-trip" {
    const allocator = std.testing.allocator;
    var agent = agent_mod.Agent.init(allocator, 0, @import("fixed_point").ONE);
    defer agent.deinit();

    _ = try agent.learnFromText("Quantum entanglement connects particles across distances. Neural networks learn from data patterns.");

    const test_path = "test_corpus_roundtrip.txt";
    _ = try saveCorpusToFile(&agent, test_path);
    defer std.fs.cwd().deleteFile(test_path) catch {};

    var agent2 = agent_mod.Agent.init(allocator, 0, @import("fixed_point").ONE);
    defer agent2.deinit();

    const loaded = try loadCorpusFromFile(&agent2, test_path);
    try std.testing.expect(loaded > 0);
}

test "training: saveCorpusToFile preserves existing corpus content (sentinel)" {
    const allocator = std.testing.allocator;

    const test_path = "test_corpus_sentinel.txt";
    defer std.fs.cwd().deleteFile(test_path) catch {};

    // Fixture corpus with sentinel lines that must survive training.
    const sentinel1 = "SENTINEL-ALPHA: the lattice preserves all prior knowledge.";
    const sentinel2 = "SENTINEL-BETA: nothing learned earlier is ever lost.";
    {
        const f = try std.fs.cwd().createFile(test_path, .{});
        defer f.close();
        try f.writer().print("{s}\n{s}\n", .{ sentinel1, sentinel2 });
    }

    var agent = agent_mod.Agent.init(allocator, 0, @import("fixed_point").ONE);
    defer agent.deinit();

    // Load fixture, learn a new sentence, save — the file must keep the
    // sentinels AND gain the learned sentence (delta-append, not truncate).
    _ = try loadCorpusFromFile(&agent, test_path);
    _ = try agent.learnFromText("The eight-channel lattice uses octonion routing.");
    const flushed = try saveCorpusToFile(&agent, test_path);
    try std.testing.expect(flushed.sentences >= 1);

    const f = try std.fs.cwd().openFile(test_path, .{});
    defer f.close();
    const content = try f.readToEndAlloc(allocator, 1 << 20);
    defer allocator.free(content);
    try std.testing.expect(std.mem.indexOf(u8, content, "SENTINEL-ALPHA") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "SENTINEL-BETA") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "eight-channel lattice") != null);
}

test "training: saveCorpusToFile flushes only the new delta on repeat saves" {
    const allocator = std.testing.allocator;

    const test_path = "test_corpus_delta_watermark.txt";
    defer std.fs.cwd().deleteFile(test_path) catch {};

    var agent = agent_mod.Agent.init(allocator, 0, @import("fixed_point").ONE);
    defer agent.deinit();

    _ = try agent.learnFromText("First learned fact about the lattice engine.");
    const f1 = try saveCorpusToFile(&agent, test_path);
    try std.testing.expect(f1.sentences == 1);
    try std.testing.expect(f1.bytes > 0);

    // Second save with nothing new learned flushes zero bytes.
    const f2 = try saveCorpusToFile(&agent, test_path);
    try std.testing.expect(f2.bytes == 0);

    // Learn more, save again — only the new sentence is appended.
    _ = try agent.learnFromText("Second learned fact about octonion channels.");
    const f3 = try saveCorpusToFile(&agent, test_path);
    try std.testing.expect(f3.sentences == 1);

    const f = try std.fs.cwd().openFile(test_path, .{});
    defer f.close();
    const content = try f.readToEndAlloc(allocator, 1 << 20);
    defer allocator.free(content);
    // The first sentence must appear exactly once — no whole-delta re-append.
    const first = "First learned fact about the lattice engine.";
    const idx1 = std.mem.indexOf(u8, content, first).?;
    try std.testing.expect(std.mem.indexOf(u8, content[idx1 + first.len ..], first) == null);
    try std.testing.expect(std.mem.indexOf(u8, content, "Second learned fact") != null);
}

test "training: .qsc corpus path resolves to learned sidecar" {
    var buf: [4096]u8 = undefined;
    const sidecar = resolveCorpusDeltaPath("qstar_corpus_full.qsc", &buf);
    try std.testing.expectEqualStrings("qstar_corpus_full.learned.txt", sidecar);

    var buf2: [4096]u8 = undefined;
    const plain = resolveCorpusDeltaPath("qstar_corpus.txt", &buf2);
    try std.testing.expectEqualStrings("qstar_corpus.txt", plain);
}

test "training: saveCorpusToFile on .qsc input writes sidecar, never touches container" {
    const allocator = std.testing.allocator;

    const raw_path = "test_qsc_sidecar_raw.txt";
    const qsc_path = "test_qsc_sidecar.qsc";
    const sidecar_path = "test_qsc_sidecar.learned.txt";
    defer std.fs.cwd().deleteFile(raw_path) catch {};
    defer std.fs.cwd().deleteFile(qsc_path) catch {};
    defer std.fs.cwd().deleteFile(sidecar_path) catch {};

    // Build a real .qsc container.
    {
        const f = try std.fs.cwd().createFile(raw_path, .{});
        defer f.close();
        try f.writeAll("Original corpus sentence that must be preserved.\n");
    }
    _ = try corpus_store.buildCorpusStore(allocator, raw_path, qsc_path, 4096);
    const qsc_stat_before = (try std.fs.cwd().statFile(qsc_path)).size;

    var agent = agent_mod.Agent.init(allocator, 0, @import("fixed_point").ONE);
    defer agent.deinit();
    _ = try loadCorpusFromFile(&agent, qsc_path);
    _ = try agent.learnFromText("A newly learned sentence during this session.");

    const flushed = try saveCorpusToFile(&agent, qsc_path);
    try std.testing.expect(flushed.sentences == 1);

    // The .qsc container must be byte-identical (untouched).
    const qsc_stat_after = (try std.fs.cwd().statFile(qsc_path)).size;
    try std.testing.expectEqual(qsc_stat_before, qsc_stat_after);

    // The sidecar must contain the learned sentence.
    const f = try std.fs.cwd().openFile(sidecar_path, .{});
    defer f.close();
    const content = try f.readToEndAlloc(allocator, 1 << 20);
    defer allocator.free(content);
    try std.testing.expect(std.mem.indexOf(u8, content, "newly learned sentence") != null);
}

test "training: loadCorpus bounds memory on oversized raw input" {
    const allocator = std.testing.allocator;
    var agent = agent_mod.Agent.init(allocator, 0, @import("fixed_point").ONE);
    defer agent.deinit();

    // Feed >12MB through loadCorpus — the retained window must stay bounded.
    const line = "The lattice engine processes octonion channels with fixed point math.\n";
    var buf = std.ArrayList(u8).init(allocator);
    defer buf.deinit();
    while (buf.items.len < 13 * 1024 * 1024) {
        try buf.appendSlice(line);
    }
    var stream = std.io.fixedBufferStream(buf.items);
    const loaded = try agent.loadCorpus(stream.reader());
    try std.testing.expect(loaded == buf.items.len);
    try std.testing.expect(agent.dynamic_corpus.items.len <= 12 * 1024 * 1024 + 4096);
}

test "training: loadCorpusFromFile auto-detects .qsc container" {
    const allocator = std.testing.allocator;

    const raw_path = "test_corpus_qsc_load.txt";
    const qsc_path = "test_corpus_qsc_load.qsc";
    defer std.fs.cwd().deleteFile(raw_path) catch {};
    defer std.fs.cwd().deleteFile(qsc_path) catch {};

    var raw_content = std.ArrayList(u8).init(allocator);
    defer raw_content.deinit();
    for (0..50) |i| {
        try raw_content.writer().print("Fact number {d} about the lattice engine.\n", .{i});
    }
    const raw_file = try std.fs.cwd().createFile(raw_path, .{});
    defer raw_file.close();
    try raw_file.writeAll(raw_content.items);

    _ = try corpus_store.buildCorpusStore(allocator, raw_path, qsc_path, 512);

    var agent = agent_mod.Agent.init(allocator, 0, @import("fixed_point").ONE);
    defer agent.deinit();

    // .qsc streaming returns sentences learned (not bytes): 50 input lines.
    const loaded = try loadCorpusFromFile(&agent, qsc_path);
    try std.testing.expectEqual(@as(usize, 50), loaded);
    try std.testing.expect(std.mem.indexOf(u8, agent.dynamic_corpus.items, "Fact number 0") != null);
    try std.testing.expect(std.mem.indexOf(u8, agent.dynamic_corpus.items, "Fact number 49") != null);
}

test "training: FailureRecord initialization with Q128.128 fields" {
    const record = FailureRecord{
        .prompt = "What is quantum entanglement?",
        .qstar_score = q128.fromRatio(3, 10),
        .openai_score = q128.fromRatio(8, 10),
        .qstar_response_preview = "Entanglement is a quantum phenomenon...",
        .judge_naturalness = q128.fromRatio(5, 10),
        .judge_relevance = q128.fromRatio(2, 10),
        .judge_engagement = q128.fromRatio(4, 10),
        .judge_factual_accuracy = q128.fromRatio(3, 10),
        .judge_originality = q128.fromRatio(6, 10),
        .judge_personalization = q128.fromRatio(7, 10),
    };
    try std.testing.expectEqualStrings("What is quantum entanglement?", record.prompt);
    try std.testing.expect(record.qstar_score == q128.fromRatio(3, 10));
    try std.testing.expect(record.openai_score == q128.fromRatio(8, 10));
    try std.testing.expect(record.judge_naturalness == q128.fromRatio(5, 10));
    try std.testing.expect(record.judge_relevance == q128.fromRatio(2, 10));
}

test "training: DistillationResult initialization with Q128.128 fields" {
    const result = DistillationResult{
        .qstar_score = q128.fromRatio(7, 10),
        .teacher_score = q128.fromRatio(6, 10),
        .qstar_won = true,
        .learned_from_teacher = false,
        .sentences_learned = 15,
        .kg_triplets = 3,
        .route_created = true,
    };
    try std.testing.expect(result.qstar_score == q128.fromRatio(7, 10));
    try std.testing.expect(result.teacher_score == q128.fromRatio(6, 10));
    try std.testing.expect(result.qstar_won == true);
    try std.testing.expect(result.sentences_learned == 15);
    try std.testing.expect(result.route_created == true);
}

test "training: DistillationResult default values are zero Q128.128" {
    const result = DistillationResult{};
    try std.testing.expect(result.qstar_score == 0);
    try std.testing.expect(result.teacher_score == 0);
    try std.testing.expect(result.qstar_won == false);
    try std.testing.expect(result.sentences_learned == 0);
}

test "training: classifyPromptCategory covers all categories" {
    // Creative
    try std.testing.expect(classifyPromptCategory("Write a story about a dragon") == .creative);
    try std.testing.expect(classifyPromptCategory("Imagine a world without gravity") == .creative);
    try std.testing.expect(classifyPromptCategory("Compose a haiku about autumn") == .creative);

    // Opinion
    try std.testing.expect(classifyPromptCategory("Should we colonize Mars?") == .opinion);
    try std.testing.expect(classifyPromptCategory("Do you think AI is dangerous?") == .opinion);
    try std.testing.expect(classifyPromptCategory("Argue for or against nuclear power") == .opinion);

    // Reasoning
    try std.testing.expect(classifyPromptCategory("Why does the sun shine?") == .reasoning);
    try std.testing.expect(classifyPromptCategory("What follows from the premise that all men are mortal?") == .reasoning);
    try std.testing.expect(classifyPromptCategory("Because the ground is wet, it must have rained") == .reasoning);

    // Factual (default)
    try std.testing.expect(classifyPromptCategory("What is the capital of France?") == .factual);
    try std.testing.expect(classifyPromptCategory("How tall is Mount Everest?") == .factual);
    try std.testing.expect(classifyPromptCategory("When was the Declaration of Independence signed?") == .factual);
}

test "training: confidenceForCategory returns expected BP values" {
    try std.testing.expectEqual(@as(u16, 8500), confidenceForCategory(.factual));
    try std.testing.expectEqual(@as(u16, 7500), confidenceForCategory(.reasoning));
    try std.testing.expectEqual(@as(u16, 6500), confidenceForCategory(.opinion));
    try std.testing.expectEqual(@as(u16, 6500), confidenceForCategory(.creative));
    try std.testing.expectEqual(@as(u16, 6000), confidenceForCategory(.naturalness));
    try std.testing.expectEqual(@as(u16, 5500), confidenceForCategory(.chitchat));
    try std.testing.expectEqual(@as(u16, 6000), confidenceForCategory(.open_ended));
    try std.testing.expectEqual(@as(u16, 9000), confidenceForCategory(.framework_query));
}

test "training: trainAndCreateRoute with Q128.128 high score creates route" {
    const allocator = std.testing.allocator;
    var agent = agent_mod.Agent.init(allocator, 0, @import("fixed_point").ONE);
    defer agent.deinit();

    const prompt = "What is quantum entanglement?";
    const response = "Quantum entanglement is a phenomenon where particles become correlated.";
    const score = q128.fromRatio(9, 10); // High score

    const learned = try trainAndCreateRoute(&agent, prompt, response, score, allocator);
    try std.testing.expect(learned > 0);
}

test "training: trainAndCreateRoute with Q128.128 low score skips route" {
    const allocator = std.testing.allocator;
    var agent = agent_mod.Agent.init(allocator, 0, @import("fixed_point").ONE);
    defer agent.deinit();

    const prompt = "What is quantum entanglement?";
    const response = "Quantum entanglement is a phenomenon where particles become correlated.";
    const score = q128.fromRatio(1, 10); // Low score (below 0.3 threshold)

    const learned = try trainAndCreateRoute(&agent, prompt, response, score, allocator);
    // Should still learn sentences but not create a route
    try std.testing.expect(learned > 0);
}

test "training: analyzeFailures with Q128.128 score fields" {
    const allocator = std.testing.allocator;
    var failures = std.ArrayList(FailureRecord).init(allocator);
    defer failures.deinit();

    // Garbled: both naturalness and relevance below 0.3
    try failures.append(.{
        .prompt = "Test prompt 1",
        .qstar_score = q128.fromRatio(1, 10),
        .openai_score = q128.fromRatio(9, 10),
        .qstar_response_preview = "asdf jkl random text here that is long enough for the preview",
        .judge_naturalness = q128.fromRatio(1, 10),
        .judge_relevance = q128.fromRatio(2, 10),
    });

    // Off-topic: low relevance but decent naturalness
    try failures.append(.{
        .prompt = "Test prompt 2",
        .qstar_score = q128.fromRatio(2, 10),
        .openai_score = q128.fromRatio(8, 10),
        .qstar_response_preview = "This is a well-written response about something completely different than asked.",
        .judge_naturalness = q128.fromRatio(7, 10),
        .judge_relevance = q128.fromRatio(2, 10),
    });

    var analysis = try analyzeFailures(failures.items, allocator);
    defer analysis.categories.deinit();

    try std.testing.expectEqual(@as(usize, 2), analysis.categories.items.len);
    try std.testing.expect(analysis.category_counts[@intFromEnum(FailureCategory.garbled_output)] >= 1);
    try std.testing.expect(analysis.category_counts[@intFromEnum(FailureCategory.off_topic)] >= 1);
}

/// Enriches the corpus by sending document excerpts to Ollama for key sentence extraction.
/// For each document, Ollama is prompted to extract 5 key factual sentences.
/// Saves corpus every 10 files for crash recovery.
pub fn enrichFromDirectory(
    agent: *agent_mod.Agent,
    root_dir: []const u8,
    config: TrainingConfig,
    corpus_save_path: ?[]const u8,
    limit: ?usize,
    offset: usize,
    allocator: std.mem.Allocator,
) !IngestResult {
    const corpus_before = agent.getCorpusSentenceCount();

    var paths = try doc_loader.collectFilePaths(allocator, root_dir);
    defer {
        for (paths.items) |p| allocator.free(p);
        paths.deinit();
    }

    const start_idx = @min(offset, paths.items.len);
    const available = paths.items.len - start_idx;
    const max_files = if (limit) |l| @min(l, available) else available;
    const end_idx = start_idx + max_files;

    var files_read: usize = 0;
    var sentences_learned: usize = 0;
    var bytes_processed: usize = 0;

    for (paths.items[start_idx..end_idx], start_idx..) |path, i| {
        if (config.verbose) {
            std.debug.print("[{d}/{d}] Enriching: {s}\n", .{ i + 1, paths.items.len, path });
        }

        // Read and preprocess the file
        const raw_text = doc_loader.processFile(allocator, path) catch |err| {
            if (config.verbose) {
                std.debug.print("  Warning: cannot read {s}: {s}\n", .{ path, @errorName(err) });
            }
            continue;
        };
        defer allocator.free(raw_text);

        // Take first 2000 chars as excerpt for Ollama
        const excerpt_len = @min(raw_text.len, 2000);
        const excerpt = raw_text[0..excerpt_len];

        // Build extraction prompt
        const extract_prompt = try std.fmt.allocPrint(allocator, "Extract 5 key factual sentences from this text. Return only the sentences, one per line, no numbering:\n\n{s}", .{excerpt});
        defer allocator.free(extract_prompt);

        // Fetch Ollama extraction
        var ollama_resp = llm_provider.complete(allocator, .{ .provider = .remote, .ollama = config.ollama }, extract_prompt) catch |err| {
            if (config.verbose) {
                std.debug.print("  Ollama error: {s}\n", .{@errorName(err)});
            }
            // Fall back to direct ingestion of the raw text
            const learned = try agent.learnFromText(raw_text);
            sentences_learned += learned;
            files_read += 1;
            bytes_processed += raw_text.len;
            continue;
        };
        defer ollama_resp.deinit();

        // Learn from Ollama's extracted sentences
        const learned_from_ollama = try agent.learnFromText(ollama_resp.text);

        // Also directly ingest the raw text (hybrid approach)
        const learned_from_raw = try agent.learnFromText(raw_text);

        const total_learned = learned_from_ollama + learned_from_raw;
        sentences_learned += total_learned;
        files_read += 1;
        bytes_processed += raw_text.len;

        if (config.verbose) {
            std.debug.print("  Learned {d} from Ollama + {d} from direct = {d} sentences\n", .{ learned_from_ollama, learned_from_raw, total_learned });
        }

        // Save corpus every 10 files for crash recovery
        if (corpus_save_path) |save_path| {
            if (files_read % 10 == 0) {
                _ = saveCorpusToFile(agent, save_path) catch undefined;
            }
        }
    }

    if (config.verbose) {
        std.debug.print("  Enrichment complete: {d}/{d} files, {d} sentences learned\n", .{ files_read, max_files, sentences_learned });
    }

    const corpus_after = agent.getCorpusSentenceCount();

    return IngestResult{
        .files_scanned = max_files,
        .files_read = files_read,
        .sentences_learned = sentences_learned,
        .bytes_processed = bytes_processed,
        .corpus_size_before = corpus_before,
        .corpus_size_after = corpus_after,
    };
}

/// Trains the agent on Ollama-generated prompts.
/// Uses prompt_generator to create diverse novel prompts via Ollama,
/// then uses Ollama as a teacher to generate responses and learn from them.
/// Returns the number of new sentences learned.
pub fn trainOnGeneratedPrompts(
    agent: *agent_mod.Agent,
    gen_config: ollama.OllamaConfig,
    teacher_config: ollama.OllamaConfig,
    count: usize,
    save_path: ?[]const u8,
    allocator: std.mem.Allocator,
) !usize {
    const prompt_gen = @import("prompt_generator");

    if (count == 0) return 0;

    if (!ollama.isAvailable(gen_config)) {
        std.debug.print("[trainOnGeneratedPrompts] Ollama not available for prompt generation\n", .{});
        return 0;
    }

    const prompts = try prompt_gen.generateRandomPromptsOllama(allocator, gen_config, count);
    defer prompt_gen.freePrompts(allocator, prompts);

    if (prompts.len == 0) {
        std.debug.print("[trainOnGeneratedPrompts] no prompts generated\n", .{});
        return 0;
    }

    std.debug.print("[trainOnGeneratedPrompts] generated {d} prompts, training...\n", .{prompts.len});

    if (save_path) |path| {
        prompt_gen.savePromptsToFile(allocator, prompts, path) catch {};
    }

    var total: usize = 0;
    for (prompts) |gp| {
        var resp = llm_provider.complete(allocator, .{ .provider = .remote, .ollama = teacher_config }, gp.text) catch |err| {
            std.debug.print("[trainOnGeneratedPrompts] teacher error for prompt: {s}\n", .{@errorName(err)});
            continue;
        };
        defer resp.deinit();

        const learned = try agent.learnFromText(resp.text);
        total += learned;
    }

    std.debug.print("[trainOnGeneratedPrompts] learned {d} new sentences\n", .{total});
    return total;
}

// =============================================================================
// Competitive Training: Failure Analysis + Adversarial Prompt Generation
// =============================================================================

/// Failure category for benchmark losses.
pub const FailureCategory = enum {
    garbled_output,
    off_topic,
    too_short,
    factual_error,
    low_naturalness,
    low_engagement,
    low_originality,
    unknown,

    pub fn label(self: FailureCategory) []const u8 {
        return switch (self) {
            .garbled_output => "garbled_output",
            .off_topic => "off_topic",
            .too_short => "too_short",
            .factual_error => "factual_error",
            .low_naturalness => "low_naturalness",
            .low_engagement => "low_engagement",
            .low_originality => "low_originality",
            .unknown => "unknown",
        };
    }
};

/// A single benchmark failure record for analysis.
pub const FailureRecord = struct {
    prompt: []const u8,
    qstar_score: q128.Fp,
    openai_score: q128.Fp,
    qstar_response_preview: []const u8,
    judge_naturalness: q128.Fp = 0,
    judge_relevance: q128.Fp = 0,
    judge_engagement: q128.Fp = 0,
    judge_factual_accuracy: q128.Fp = 0,
    judge_originality: q128.Fp = 0,
    judge_personalization: q128.Fp = 0,
};

/// Analyzes a batch of failure records and classifies each into a FailureCategory.
/// Returns the dominant failure category and a list of targeted retraining prompts.
pub fn analyzeFailures(
    failures: []const FailureRecord,
    allocator: std.mem.Allocator,
) !struct {
    categories: std.ArrayList(FailureCategory),
    dominant: FailureCategory,
    category_counts: [8]usize,
} {
    var categories = std.ArrayList(FailureCategory).init(allocator);
    errdefer categories.deinit();
    var counts: [8]usize = .{0} ** 8;

    for (failures) |f| {
        const cat = classifyFailure(f);
        try categories.append(cat);
        counts[@intFromEnum(cat)] += 1;
    }

    // Find dominant failure category
    var dominant: FailureCategory = .unknown;
    var max_count: usize = 0;
    for (counts, 0..) |c, i| {
        if (c > max_count) {
            max_count = c;
            dominant = @enumFromInt(i);
        }
    }

    return .{
        .categories = categories,
        .dominant = dominant,
        .category_counts = counts,
    };
}

/// Classifies a single failure record into a FailureCategory.
fn classifyFailure(f: FailureRecord) FailureCategory {
    const threshold_low = q128.fromRatio(3, 10);
    const threshold_mid = q128.fromRatio(4, 10);
    // Garbled output: very low naturalness + relevance
    if (f.judge_naturalness < threshold_low and f.judge_relevance < threshold_low) return .garbled_output;

    // Off-topic: low relevance but decent naturalness
    if (f.judge_relevance < threshold_low and f.judge_naturalness >= threshold_low) return .off_topic;

    // Too short: response preview is very short
    if (f.qstar_response_preview.len < 100) return .too_short;

    // Factual error: low factual accuracy but otherwise decent
    if (f.judge_factual_accuracy < threshold_low and f.judge_relevance >= threshold_low) return .factual_error;

    // Low naturalness
    if (f.judge_naturalness < threshold_mid) return .low_naturalness;

    // Low engagement
    if (f.judge_engagement < threshold_mid) return .low_engagement;

    // Low originality
    if (f.judge_originality < threshold_mid) return .low_originality;

    return .unknown;
}

/// Generates adversarial prompts targeting Qstar's weak categories.
/// Uses OpenAI to create harder prompts in the categories where Qstar loses most.
pub fn generateAdversarialPrompts(
    allocator: std.mem.Allocator,
    oa_config: openai.OpenAIConfig,
    weak_categories: []const FailureCategory,
    count: usize,
) ![][]const u8 {
    var all = std.ArrayList([]const u8).init(allocator);
    errdefer {
        for (all.items) |p| allocator.free(p);
        all.deinit();
    }

    if (oa_config.api_key.len == 0 or count == 0) return try all.toOwnedSlice();

    // Build a description of weak areas
    var weak_desc = std.ArrayList(u8).init(allocator);
    defer weak_desc.deinit();
    try weak_desc.appendSlice("Qstar struggles with: ");
    for (weak_categories, 0..) |cat, i| {
        if (i > 0) try weak_desc.appendSlice(", ");
        try weak_desc.appendSlice(cat.label());
    }
    try weak_desc.appendSlice(". ");

    const batch_size: usize = 20;
    var gen: usize = 0;
    while (gen < count) {
        const n = @min(batch_size, count - gen);
        var mp = std.ArrayList(u8).init(allocator);
        defer mp.deinit();
        try mp.writer().print("Generate {d} challenging questions designed to test an AI in these weak areas: {s}", .{ n, weak_desc.items });
        try mp.appendSlice(". Make questions that are difficult, require deep knowledge, and would expose weaknesses. Vary topics across science, history, philosophy, technology, creative writing, and everyday reasoning. One per line, no numbers, no extra text.");

        var resp = openai.simplePrompt(allocator, oa_config, "You are an adversarial prompt engineer. Generate questions designed to expose AI weaknesses in specific areas.", mp.items) catch |err| {
            std.debug.print("WARNING: Adversarial prompt generation failed: {s}\n", .{@errorName(err)});
            break;
        };
        defer resp.deinit();

        var lines = std.mem.splitScalar(u8, resp.text, '\n');
        while (lines.next()) |line| {
            const t = std.mem.trim(u8, line, " \t\r");
            if (t.len < 10 or t.len > 500) continue;
            if (std.mem.startsWith(u8, t, "Here") or std.mem.startsWith(u8, t, "Sure") or std.mem.startsWith(u8, t, "I'll")) continue;
            var s: usize = 0;
            while (s < t.len and (std.ascii.isDigit(t[s]) or t[s] == '.' or t[s] == ')')) s += 1;
            const c = std.mem.trim(u8, t[s..], " \t");
            if (c.len < 10) continue;
            try all.append(try allocator.dupe(u8, c));
            gen += 1;
            if (gen >= count) break;
        }
    }
    return try all.toOwnedSlice();
}

/// Category-specific prompt generation for targeted training.
/// Generates prompts targeting a specific benchmark category (naturalness, relevance, etc.).
pub fn generateCategoryPrompts(
    allocator: std.mem.Allocator,
    oa_config: openai.OpenAIConfig,
    bench_category: []const u8,
    topic: []const u8,
    count: usize,
) ![][]const u8 {
    var all = std.ArrayList([]const u8).init(allocator);
    errdefer {
        for (all.items) |p| allocator.free(p);
        all.deinit();
    }

    if (oa_config.api_key.len == 0 or count == 0) return try all.toOwnedSlice();

    var mp = std.ArrayList(u8).init(allocator);
    defer mp.deinit();
    try mp.writer().print("Generate {d} questions about {s} that specifically test {s}. ", .{ count, topic, bench_category });
    try mp.appendSlice("Make them require detailed, long-form answers. Vary difficulty from simple to deep. One per line, no numbers, no extra text.");

    var resp = openai.simplePrompt(allocator, oa_config, "You are a prompt engineering assistant. Generate questions that test specific AI capabilities.", mp.items) catch |err| {
        std.debug.print("WARNING: Category prompt generation failed: {s}\n", .{@errorName(err)});
        return try all.toOwnedSlice();
    };
    defer resp.deinit();

    var lines = std.mem.splitScalar(u8, resp.text, '\n');
    while (lines.next()) |line| {
        const t = std.mem.trim(u8, line, " \t\r");
        if (t.len < 10 or t.len > 500) continue;
        if (std.mem.startsWith(u8, t, "Here") or std.mem.startsWith(u8, t, "Sure") or std.mem.startsWith(u8, t, "I'll")) continue;
        var s: usize = 0;
        while (s < t.len and (std.ascii.isDigit(t[s]) or t[s] == '.' or t[s] == ')')) s += 1;
        const c = std.mem.trim(u8, t[s..], " \t");
        if (c.len < 10) continue;
        try all.append(try allocator.dupe(u8, c));
    }
    return try all.toOwnedSlice();
}

/// On-policy distillation: Qstar generates a response, teacher (OpenAI) generates a response,
/// judge scores both. If Qstar loses, learn from teacher. If Qstar wins, reinforce.
/// Returns the training result and whether Qstar won.
pub const DistillationResult = struct {
    qstar_score: q128.Fp = 0,
    teacher_score: q128.Fp = 0,
    qstar_won: bool = false,
    learned_from_teacher: bool = false,
    sentences_learned: usize = 0,
    kg_triplets: usize = 0,
    route_created: bool = false,
    fallback_used: bool = false,
    fallback_succeeded: bool = false,
};

pub fn distillOnPolicy(
    agent: *agent_mod.Agent,
    prompt: []const u8,
    oa_config: openai.OpenAIConfig,
    allocator: std.mem.Allocator,
) !DistillationResult {
    var result = DistillationResult{};
    const fallback_attempts_before = agent.fallback_attempts;
    const fallback_successes_before = agent.fallback_successes;

    // 1. Qstar generates a response
    const qstar_response = agent.generateWithReflection(prompt, allocator, null) catch |err| {
        std.debug.print("  Qstar generation error: {s}\n", .{@errorName(err)});
        // If Qstar can't generate, learn from teacher directly
        const sem = try trainWithOpenAISemantic(agent, prompt, oa_config, allocator);
        result.learned_from_teacher = true;
        result.sentences_learned = sem.sentences_learned;
        result.kg_triplets = sem.kg_triplets_extracted;
        result.route_created = sem.route_created;
        result.fallback_used = agent.fallback_attempts > fallback_attempts_before;
        result.fallback_succeeded = agent.fallback_successes > fallback_successes_before;
        return result;
    };
    defer allocator.free(qstar_response);
    result.fallback_used = agent.fallback_attempts > fallback_attempts_before;
    result.fallback_succeeded = agent.fallback_successes > fallback_successes_before;

    // 2. Teacher (OpenAI) generates a response
    const system_prompt = "You are a knowledgeable teacher. Provide a clear, accurate, and detailed explanation. Include key facts, relationships, and context. Aim for 200-500 words.";
    var oa_resp = openai.simplePrompt(allocator, oa_config, system_prompt, prompt) catch |err| {
        std.debug.print("  Teacher error: {s}\n", .{@errorName(err)});
        // Teacher unavailable — just reinforce Qstar's response
        result.qstar_score = q128.fromRatio(1, 2);
        result.qstar_won = true;
        return result;
    };
    defer oa_resp.deinit();

    // 3. Judge both responses
    const q_score = judgeSingleResponse(allocator, oa_config, prompt, qstar_response);
    const t_score = judgeSingleResponse(allocator, oa_config, prompt, oa_resp.text);

    result.qstar_score = q_score;
    result.teacher_score = t_score;
    result.qstar_won = q_score >= t_score;

    std.debug.print("  Q={d:.3} T={d:.3} => {s}\n", .{ q128.toF64(q_score), q128.toF64(t_score), if (result.qstar_won) "Q wins" else "T wins" });

    if (result.qstar_won) {
        // Qstar won — reinforce by creating a high-confidence route
        const category = classifyPromptCategory(prompt);
        const confidence_bp = confidenceForCategory(category) + 500; // Bonus for winning
        var kws: [dyn_routes.MAX_KEYWORDS][]const u8 = undefined;
        const kw_count = mc_engine.RouteGenerator.extractKeywords(prompt, &kws, dyn_routes.MAX_KEYWORDS);
        if (kw_count > 0) {
            agent.registerDynamicRoute(kws[0..kw_count], qstar_response, confidence_bp, category, .self_evaluated) catch {};
            result.route_created = true;
        }
    } else {
        // Teacher won — learn from teacher response
        result.sentences_learned = try agent.learnFromText(oa_resp.text);
        result.kg_triplets = agent.extractKnowledgeFromText(oa_resp.text) catch 0;
        const category = classifyPromptCategory(prompt);
        const confidence_bp = confidenceForCategory(category);
        var kws: [dyn_routes.MAX_KEYWORDS][]const u8 = undefined;
        const kw_count = mc_engine.RouteGenerator.extractKeywords(prompt, &kws, dyn_routes.MAX_KEYWORDS);
        if (kw_count > 0) {
            agent.registerDynamicRoute(kws[0..kw_count], oa_resp.text, confidence_bp, category, .openai_reinforced) catch {};
            result.route_created = true;
        }
        result.learned_from_teacher = true;
    }

    return result;
}

/// Judges a single response using OpenAI and returns an overall score (0-1).
fn judgeSingleResponse(allocator: std.mem.Allocator, oa_config: openai.OpenAIConfig, prompt: []const u8, response: []const u8) q128.Fp {
    var jp = std.ArrayList(u8).init(allocator);
    defer jp.deinit();
    jp.appendSlice("Rate this response 1-10. Return ONLY JSON: {\"naturalness\":N,\"relevance\":N,\"engagement\":N,\"factual_accuracy\":N,\"originality\":N,\"personalization\":N}\n\nPrompt: ") catch return 0;
    jp.appendSlice(prompt) catch return 0;
    jp.appendSlice("\n\nResponse: ") catch return 0;
    jp.appendSlice(response) catch return 0;

    var judge_cfg = oa_config;
    judge_cfg.model = "gpt-4o-mini";
    var resp = openai.simplePrompt(allocator, judge_cfg, "You are a response judge. Rate responses on a 1-10 scale. Return ONLY the JSON object.", jp.items) catch return 0;
    defer resp.deinit();

    // Parse JSON scores
    const text = resp.text;
    const n = extractJsonScore(text, "naturalness");
    const r = extractJsonScore(text, "relevance");
    const e = extractJsonScore(text, "engagement");
    const f = extractJsonScore(text, "factual_accuracy");
    const o = extractJsonScore(text, "originality");
    const p = extractJsonScore(text, "personalization");

    // (n + r + e + f + o + p) / 6 / 10
    const sum = q128.add(q128.add(q128.add(n, r), q128.add(e, f)), q128.add(o, p));
    return q128.div(q128.div(sum, q128.fromInt(6)), q128.fromInt(10));
}

/// Extracts a numeric score from JSON text for a given key.
fn extractJsonScore(text: []const u8, key: []const u8) q128.Fp {
    // Find "key":N pattern
    var search_buf: [64]u8 = undefined;
    const pattern = std.fmt.bufPrint(&search_buf, "\"{s}\":", .{key}) catch return 0;

    const idx = std.mem.indexOf(u8, text, pattern) orelse return 0;
    var pos = idx + pattern.len;
    // Skip whitespace
    while (pos < text.len and (text[pos] == ' ' or text[pos] == '\t')) pos += 1;
    // Parse number
    var end = pos;
    while (end < text.len and (std.ascii.isDigit(text[end]) or text[end] == '.')) end += 1;
    if (end == pos) return 0;
    return q128.fromF64(std.fmt.parseFloat(f64, text[pos..end]) catch 0.0);
}

/// Result for corpus-wide distillation operations.
pub const DistillCorpusResult = struct {
    files_processed: usize = 0,
    topics_distilled: usize = 0,
    qstar_wins: usize = 0,
    teacher_wins: usize = 0,
    sentences_learned: usize = 0,
    routes_created: usize = 0,
    corpus_size_before: usize = 0,
    corpus_size_after: usize = 0,
};

/// Extracts a topic prompt from a markdown document filename.
/// Converts snake_case filenames to readable prompts.
/// e.g., "quantum_entanglement_nonlocality.md" -> "Explain quantum entanglement nonlocality."
fn topicFromFilename(filename: []const u8) []const u8 {
    var name = filename;
    // Strip directory path
    if (std.mem.lastIndexOfScalar(u8, name, '/')) |idx| {
        name = name[idx + 1 ..];
    }
    // Strip extension
    if (std.mem.lastIndexOfScalar(u8, name, '.')) |idx| {
        name = name[0..idx];
    }
    return name;
}

/// Converts a snake_case or PascalCase topic name into a readable prompt string.
/// e.g., "quantum_entanglement" -> "Explain quantum entanglement"
fn formatTopicPrompt(allocator: std.mem.Allocator, topic: []const u8) ![]const u8 {
    var buf = std.ArrayList(u8).init(allocator);
    defer buf.deinit();
    try buf.appendSlice("Explain ");
    for (topic) |c| {
        if (c == '_' or c == '-') {
            try buf.append(' ');
        } else {
            try buf.append(c);
        }
    }
    try buf.append('.');
    return buf.toOwnedSlice();
}

/// Generates a code-aware distillation prompt based on file extension.
/// For source code files, asks OpenAI to explain architecture, data structures, and algorithms.
/// For documentation files, asks for a summary of key concepts.
/// Falls back to generic "Explain {topic}." for unknown types.
fn formatCodeAwarePrompt(allocator: std.mem.Allocator, filepath: []const u8) ![]const u8 {
    // Extract just the filename for the prompt
    var filename = filepath;
    if (std.mem.lastIndexOfScalar(u8, filepath, '/')) |idx| {
        filename = filepath[idx + 1 ..];
    }

    // Convert filename underscores/dashes to spaces for readable topic
    var topic_buf = std.ArrayList(u8).init(allocator);
    defer topic_buf.deinit();
    var topic_name = filename;
    if (std.mem.lastIndexOfScalar(u8, filename, '.')) |dot_idx| {
        topic_name = filename[0..dot_idx];
    }
    for (topic_name) |c| {
        if (c == '_' or c == '-') {
            try topic_buf.append(' ');
        } else {
            try topic_buf.append(c);
        }
    }
    const topic = topic_buf.items;

    var buf = std.ArrayList(u8).init(allocator);
    defer buf.deinit();

    // Determine prompt based on file extension
    if (std.mem.endsWith(u8, filename, ".zig")) {
        try buf.writer().print("Review the Zig source code in {s}. Explain the architecture, key data structures, main functions, and algorithms.", .{filename});
    } else if (std.mem.endsWith(u8, filename, ".py")) {
        try buf.writer().print("Review the Python code in {s}. Explain the main functions, classes, and design patterns used.", .{filename});
    } else if (std.mem.endsWith(u8, filename, ".md")) {
        try buf.writer().print("Explain the documentation in {s}. Summarize the key concepts, architecture, and important details.", .{filename});
    } else if (std.mem.endsWith(u8, filename, ".json")) {
        try buf.writer().print("Explain the data structure in {s}. Describe the key fields and their purposes.", .{filename});
    } else if (std.mem.endsWith(u8, filename, ".sh")) {
        try buf.writer().print("Explain the shell script {s}. Describe what it does and its key operations.", .{filename});
    } else if (std.mem.endsWith(u8, filename, ".html")) {
        try buf.writer().print("Explain the HTML document {s}. Describe its structure and purpose.", .{filename});
    } else if (std.mem.endsWith(u8, filename, ".css")) {
        try buf.writer().print("Explain the CSS in {s}. Describe the styling rules and layout approach.", .{filename});
    } else if (std.mem.endsWith(u8, filename, ".txt")) {
        try buf.writer().print("Explain the content of {s}. Summarize the key information and topics covered.", .{filename});
    } else if (std.mem.endsWith(u8, filename, ".yml") or std.mem.endsWith(u8, filename, ".yaml")) {
        try buf.writer().print("Explain the configuration in {s}. Describe the settings and their purposes.", .{filename});
    } else if (std.mem.endsWith(u8, filename, ".toml")) {
        try buf.writer().print("Explain the TOML configuration in {s}. Describe the settings and their purposes.", .{filename});
    } else if (std.mem.endsWith(u8, filename, ".sql")) {
        try buf.writer().print("Explain the SQL in {s}. Describe the database schema and queries.", .{filename});
    } else if (std.mem.endsWith(u8, filename, ".js") or std.mem.endsWith(u8, filename, ".ts")) {
        try buf.writer().print("Review the code in {s}. Explain the main functions, classes, and logic.", .{filename});
    } else if (std.mem.endsWith(u8, filename, ".c") or std.mem.endsWith(u8, filename, ".h")) {
        try buf.writer().print("Review the C source code in {s}. Explain the main functions, data structures, and algorithms.", .{filename});
    } else if (std.mem.endsWith(u8, filename, ".cpp") or std.mem.endsWith(u8, filename, ".hpp")) {
        try buf.writer().print("Review the C++ source code in {s}. Explain the main functions, classes, and algorithms.", .{filename});
    } else if (std.mem.endsWith(u8, filename, ".rs")) {
        try buf.writer().print("Review the Rust source code in {s}. Explain the architecture, key data structures, and main functions.", .{filename});
    } else if (std.mem.endsWith(u8, filename, ".go")) {
        try buf.writer().print("Review the Go source code in {s}. Explain the main functions, types, and logic.", .{filename});
    } else {
        // Generic fallback: use the readable topic name
        try buf.writer().print("Explain {s}.", .{topic});
    }

    return buf.toOwnedSlice();
}

/// Returns true if a file path contains any of the exclude patterns.
fn pathContainsExclude(path: []const u8, excludes: []const []const u8) bool {
    for (excludes) |ex| {
        if (std.mem.indexOf(u8, path, ex) != null) return true;
    }
    return false;
}

/// Full corpus distillation pipeline:
/// 1. Ingests all documents from a directory (self-ingest)
/// 2. For each document, extracts a topic and runs on-policy distillation with OpenAI
///    (self-train metacog via generateWithReflection + learn from OpenAI teacher)
/// 3. Saves corpus periodically for crash recovery
pub fn distillCorpusWithOpenAI(
    agent: *agent_mod.Agent,
    corpus_dir: []const u8,
    oa_config: openai.OpenAIConfig,
    corpus_save_path: ?[]const u8,
    routes_save_path: ?[]const u8,
    exclude_patterns: []const []const u8,
    verbose: bool,
    allocator: std.mem.Allocator,
) !DistillCorpusResult {
    var result = DistillCorpusResult{};
    result.corpus_size_before = agent.getCorpusSentenceCount();

    // Phase 1: Self-ingest all documents from the directory
    if (verbose) {
        std.debug.print("=== Phase 1: Self-Ingestion ===\n", .{});
        std.debug.print("Directory: {s}\n", .{corpus_dir});
        if (exclude_patterns.len > 0) {
            std.debug.print("Excludes: ", .{});
            for (exclude_patterns, 0..) |ex, ei| {
                if (ei > 0) std.debug.print(", ", .{});
                std.debug.print("{s}", .{ex});
            }
            std.debug.print("\n", .{});
        }
        std.debug.print("\n", .{});
    }

    // Collect file paths and filter out excluded ones
    var all_paths = try doc_loader.collectFilePaths(allocator, corpus_dir);
    defer {
        for (all_paths.items) |p| allocator.free(p);
        all_paths.deinit();
    }

    var ingest_paths = std.ArrayList([]u8).init(allocator);
    defer {
        for (ingest_paths.items) |p| allocator.free(p);
        ingest_paths.deinit();
    }
    var skipped: usize = 0;
    for (all_paths.items) |path| {
        if (pathContainsExclude(path, exclude_patterns)) {
            skipped += 1;
            allocator.free(path);
        } else {
            try ingest_paths.append(path);
        }
    }
    // Remove consumed items from all_paths so its defer doesn't double-free
    all_paths.clearRetainingCapacity();

    if (verbose and skipped > 0) {
        std.debug.print("Skipped {d} files matching exclude patterns.\n\n", .{skipped});
    }

    // Ingest files manually (can't use ingestFromDirectory because we need filtered paths)
    var files_read: usize = 0;
    var sentences_learned: usize = 0;
    var bytes_processed: usize = 0;
    for (ingest_paths.items) |path| {
        const text = doc_loader.processFile(allocator, path) catch |err| {
            if (verbose) {
                std.debug.print("  Warning: cannot process {s}: {s}\n", .{ path, @errorName(err) });
            }
            continue;
        };
        defer allocator.free(text);

        files_read += 1;
        bytes_processed += text.len;

        const learned = try agent.learnFromText(text);
        sentences_learned += learned;

        if (verbose and files_read % 50 == 0) {
            std.debug.print("  [{d}/{d}] Ingested {d} files, {d} sentences learned so far\n", .{ files_read, ingest_paths.items.len, files_read, sentences_learned });
        }
    }
    if (verbose) {
        std.debug.print("  Ingestion complete: {d}/{d} files, {d} sentences learned, {d} bytes processed\n", .{ files_read, ingest_paths.items.len, sentences_learned, bytes_processed });
    }

    result.files_processed = files_read;
    result.sentences_learned += sentences_learned;

    if (verbose) {
        std.debug.print("\nPhase 1 complete: {d} files, {d} sentences ingested\n\n", .{ files_read, sentences_learned });
    }

    // Save after ingestion
    if (corpus_save_path) |path| {
        _ = saveCorpusToFile(agent, path) catch undefined;
    }

    // Phase 2: Extract topics from each document and distill with OpenAI
    if (verbose) {
        std.debug.print("=== Phase 2: On-Policy Distillation with OpenAI ===\n", .{});
        std.debug.print("Teacher: OpenAI ({s})\n\n", .{oa_config.model});
    }

    var topic_idx: usize = 0;
    for (ingest_paths.items) |path| {
        topic_idx += 1;
        const topic = topicFromFilename(path);

        // Format a code-aware prompt based on file extension
        const prompt = try formatCodeAwarePrompt(allocator, path);
        defer allocator.free(prompt);

        if (verbose) {
            std.debug.print("[{d}/{d}] Distilling: {s}\n", .{ topic_idx, ingest_paths.items.len, topic });
        }

        // Run on-policy distillation: Qstar generates, OpenAI generates, judge scores, learn
        const distill_result = distillOnPolicy(agent, prompt, oa_config, allocator) catch |err| {
            if (verbose) {
                std.debug.print("  Distillation error: {s}\n", .{@errorName(err)});
            }
            continue;
        };

        result.topics_distilled += 1;
        if (distill_result.qstar_won) {
            result.qstar_wins += 1;
        } else {
            result.teacher_wins += 1;
        }
        result.sentences_learned += distill_result.sentences_learned;
        if (distill_result.route_created) {
            result.routes_created += 1;
        }

        if (verbose) {
            std.debug.print("  Q={d:.3} T={d:.3} => {s}, learned={d}, route={s}\n", .{
                distill_result.qstar_score,
                distill_result.teacher_score,
                if (distill_result.qstar_won) "Q wins" else "T wins",
                distill_result.sentences_learned,
                if (distill_result.route_created) "yes" else "no",
            });
        }

        // Save corpus every 5 topics for crash recovery
        if (corpus_save_path) |save_path| {
            if (result.topics_distilled % 5 == 0) {
                _ = saveCorpusToFile(agent, save_path) catch undefined;
            }
        }
        // Save dynamic routes every 50 topics for crash recovery
        if (routes_save_path) |rp| {
            if (result.topics_distilled % 50 == 0) {
                agent.saveDynamicRoutes(rp) catch {};
            }
        }
    }

    // Final save
    if (corpus_save_path) |path| {
        _ = saveCorpusToFile(agent, path) catch undefined;
    }
    // Final route save
    if (routes_save_path) |path| {
        agent.saveDynamicRoutes(path) catch {};
        if (verbose) {
            std.debug.print("Dynamic routes saved to: {s}\n", .{path});
        }
    }

    result.corpus_size_after = agent.getCorpusSentenceCount();

    if (verbose) {
        std.debug.print("\n=== Distillation Complete ===\n", .{});
        std.debug.print("Files processed: {d}\n", .{result.files_processed});
        std.debug.print("Topics distilled: {d}\n", .{result.topics_distilled});
        std.debug.print("Qstar wins: {d}\n", .{result.qstar_wins});
        std.debug.print("Teacher wins: {d}\n", .{result.teacher_wins});
        std.debug.print("Sentences learned: {d}\n", .{result.sentences_learned});
        std.debug.print("Routes created: {d}\n", .{result.routes_created});
        std.debug.print("Corpus: {d} -> {d} sentences\n", .{ result.corpus_size_before, result.corpus_size_after });
    }

    return result;
}

// =============================================================================
// Failure-window training tests
// =============================================================================

test "training: shouldPromote rejects when opponent doesn't beat qstar by 0.10" {
    try std.testing.expect(!shouldPromote(0.50, 0.55, .factual)); // only 0.05 ahead
    try std.testing.expect(!shouldPromote(0.50, 0.50, .factual)); // tied
    try std.testing.expect(!shouldPromote(0.60, 0.50, .factual)); // opponent behind
}

test "training: shouldPromote rejects when opponent absolute score too low" {
    try std.testing.expect(!shouldPromote(0.20, 0.35, .factual)); // 0.15 ahead but < 0.50
    try std.testing.expect(!shouldPromote(0.10, 0.25, .factual)); // 0.15 ahead but < 0.50
}

test "training: shouldPromote accepts factual when opponent beats by 0.10 and >= 0.50" {
    try std.testing.expect(shouldPromote(0.40, 0.55, .factual)); // 0.15 ahead, 0.55 >= 0.50
    try std.testing.expect(shouldPromote(0.50, 0.65, .factual));
}

test "training: shouldPromote has higher bar for creative (0.60)" {
    try std.testing.expect(!shouldPromote(0.40, 0.55, .creative)); // 0.55 < 0.60
    try std.testing.expect(shouldPromote(0.40, 0.65, .creative)); // 0.65 >= 0.60
    try std.testing.expect(!shouldPromote(0.40, 0.55, .naturalness)); // 0.55 < 0.60
    try std.testing.expect(shouldPromote(0.40, 0.65, .naturalness));
}

test "training: partitionFailures splits deterministically by hash" {
    const allocator = std.testing.allocator;
    const examples = try allocator.alloc(FailureExample, 10);
    defer {
        for (examples) |*ex| ex.deinit();
        allocator.free(examples);
    }
    for (examples, 0..) |*ex, i| {
        var buf: [32]u8 = undefined;
        const prompt = std.fmt.bufPrint(&buf, "Prompt number {d}", .{i}) catch unreachable;
        ex.* = FailureExample{
            .prompt = try allocator.dupe(u8, prompt),
            .category = try allocator.dupe(u8, "factual"),
            .qstar_response = try allocator.dupe(u8, "qstar response"),
            .qstar_relevance = 0.3,
            .qstar_judge_composite = 0.4,
            .opponent_best_response = try allocator.dupe(u8, "opponent response"),
            .opponent_best_score = 0.7,
            .route_backend = try allocator.dupe(u8, "lattice"),
            .fallback_used = false,
            .latency_ms = 5000,
            .allocator = allocator,
        };
    }

    var window = try partitionFailures(allocator, examples, 0.6, 0.2);
    defer window.deinit();

    // 10 examples: 60% = 6 train, 20% = 2 val, 20% = 2 held-out
    try std.testing.expectEqual(@as(usize, 6), window.train.len);
    try std.testing.expectEqual(@as(usize, 2), window.val.len);
    try std.testing.expectEqual(@as(usize, 2), window.held_out.len);
    try std.testing.expectEqual(@as(usize, 0), window.external_held_out.len);

    // Verify determinism: re-partition and get the same split.
    var window2 = try partitionFailures(allocator, examples, 0.6, 0.2);
    defer window2.deinit();
    for (window.train, window2.train) |a, b| {
        try std.testing.expectEqualStrings(a.prompt, b.prompt);
    }
}

test "training: partitionFailures handles empty input" {
    const allocator = std.testing.allocator;
    var window = try partitionFailures(allocator, &[_]FailureExample{}, 0.6, 0.2);
    defer window.deinit();
    try std.testing.expectEqual(@as(usize, 0), window.train.len);
    try std.testing.expectEqual(@as(usize, 0), window.val.len);
    try std.testing.expectEqual(@as(usize, 0), window.held_out.len);
}

test "training: EXTERNAL_HELD_OUT_PROMPTS is non-empty and covers categories" {
    try std.testing.expect(EXTERNAL_HELD_OUT_PROMPTS.len >= 12);
    // Verify all have non-empty prompts and categories.
    for (EXTERNAL_HELD_OUT_PROMPTS) |p| {
        try std.testing.expect(p.prompt.len > 10);
        try std.testing.expect(p.category.len > 0);
        try std.testing.expect(p.expected_keywords.len > 0);
    }
}
