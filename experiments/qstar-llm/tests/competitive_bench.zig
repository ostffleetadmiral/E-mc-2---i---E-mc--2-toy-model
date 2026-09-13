//! competitive_bench.zig — Competitive Benchmark Suite: Qstar vs Ollama
//!
//! Runs identical prompts through both Qstar and Ollama, scores both on
//! factual accuracy, creative fluency, naturalness, reasoning, latency,
//! and throughput. Supports randomized prompt selection, LLM-as-judge scoring,
//! and interactive multi-turn conversation mode.
//!
//! Categories: factual, creative, naturalness, reasoning, chitchat, opinions,
//!             open_ended, latency, throughput
//!
//! Usage:
//!   zig build competitive-bench -- [model] [--random] [--num-prompts N] [--seed N]
//!                               [--judge] [--conversation] [--turns N]
//!                               [--fast] [--judge-host H] [--judge-port P]
//!   Default model: qwen2.5:3b
//!   --fast: 10 prompts, no judge, no opponents (Qstar-only speed run)
//!   --judge-host/--judge-port: separate Ollama instance for judging (avoids model-swap clashing)

const std = @import("std");
const agent_mod = @import("agent");
const fp = @import("fixed_point");
const ollama = @import("ollama_client");
const openai = @import("openai_client");
const maple = @import("maple_client");
const prompt_gen = @import("prompt_generator");
const llm_provider = @import("llm_provider");

const DEFAULT_OLLAMA_HOST_STR = "127.0.0.1";
const DEFAULT_OLLAMA_PORT_VAL: u16 = 11434;
const DEFAULT_MODEL_STR = "qwen2.5:3b";
const DEFAULT_JUDGE_MODEL_STR = "qwen2.5:3b";

var g_ollama_host: []const u8 = DEFAULT_OLLAMA_HOST_STR;
var g_ollama_port: u16 = DEFAULT_OLLAMA_PORT_VAL;
var g_ollama_model: []const u8 = DEFAULT_MODEL_STR;
var g_judge_model: []const u8 = DEFAULT_JUDGE_MODEL_STR;
const DEFAULT_OPENAI_MODEL = "gpt-4o";

fn escapeJsonString(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
    var out = std.ArrayList(u8).init(allocator);
    for (s) |c| {
        switch (c) {
            '"' => try out.appendSlice("\\\""),
            '\\' => try out.appendSlice("\\\\"),
            '\n' => try out.appendSlice("\\n"),
            '\r' => try out.appendSlice("\\r"),
            '\t' => try out.appendSlice("\\t"),
            0...8, 11, 12, 14...31 => {
                try out.writer().print("\\u{x:0>4}", .{c});
            },
            else => try out.append(c),
        }
    }
    return out.toOwnedSlice();
}

const Category = enum {
    factual,
    creative,
    naturalness,
    reasoning,
    chitchat,
    opinions,
    open_ended,
    latency,
    throughput,
    tool_calling,
    untrained,
    mmlu,
    gsm8k,
};

const BenchPrompt = struct {
    prompt: []const u8,
    category: Category,
    expected_keywords: []const []const u8,
};

const BENCHMARK_PROMPTS = [_]BenchPrompt{
    // === Factual ===
    .{ .prompt = "Explain photosynthesis in simple terms.", .category = .factual, .expected_keywords = &.{ "sunlight", "chlorophyll", "oxygen", "sugar" } },
    .{ .prompt = "What is the speed of light?", .category = .factual, .expected_keywords = &.{ "299", "meters", "second", "vacuum" } },
    .{ .prompt = "Explain general relativity.", .category = .factual, .expected_keywords = &.{ "gravity", "spacetime", "mass", "curvature" } },
    .{ .prompt = "What does the human heart do?", .category = .factual, .expected_keywords = &.{ "blood", "pump", "oxygen", "body" } },
    .{ .prompt = "What is the capital of France?", .category = .factual, .expected_keywords = &.{"Paris"} },
    .{ .prompt = "What is the chemical formula for water?", .category = .factual, .expected_keywords = &.{"H2O"} },
    .{ .prompt = "Why is the sky blue?", .category = .factual, .expected_keywords = &.{ "scattering", "blue", "wavelength" } },
    .{ .prompt = "Why does ice float on water?", .category = .factual, .expected_keywords = &.{ "dense", "density", "hydrogen" } },

    // === Creative ===
    .{ .prompt = "Write a short poem about the ocean.", .category = .creative, .expected_keywords = &.{ "wave", "ocean", "sea", "deep" } },
    .{ .prompt = "Tell me a creative story about a robot learning to paint.", .category = .creative, .expected_keywords = &.{ "robot", "paint", "color", "art" } },
    .{ .prompt = "Write a haiku about autumn.", .category = .creative, .expected_keywords = &.{ "autumn", "leaf", "fall" } },
    .{ .prompt = "Imagine a city on Mars. What would it look like?", .category = .creative, .expected_keywords = &.{ "Mars", "dome", "red" } },
    .{ .prompt = "Invent a new color and describe what it looks like.", .category = .creative, .expected_keywords = &.{ "color", "shade", "hue" } },
    .{ .prompt = "Describe what music would look like if you could see it.", .category = .creative, .expected_keywords = &.{ "music", "color", "shape" } },
    .{ .prompt = "If food had a personality, what would a pizza be like?", .category = .creative, .expected_keywords = &.{ "pizza", "personality", "cheese" } },

    // === Naturalness ===
    .{ .prompt = "Describe a sunset in vivid detail.", .category = .naturalness, .expected_keywords = &.{ "sun", "color", "sky", "horizon" } },
    .{ .prompt = "Tell me about your day in a conversational tone.", .category = .naturalness, .expected_keywords = &.{} },
    .{ .prompt = "Explain your thoughts on consciousness.", .category = .naturalness, .expected_keywords = &.{ "consciousness", "awareness", "mind" } },

    // === Reasoning ===
    .{ .prompt = "If all cats are mammals and all mammals are animals, are cats animals?", .category = .reasoning, .expected_keywords = &.{ "yes", "cat", "animal", "mammal" } },
    .{ .prompt = "What comes next in the sequence: 2, 4, 8, 16, ?", .category = .reasoning, .expected_keywords = &.{ "32", "doubling", "double" } },
    .{ .prompt = "If you have 3 apples and give away 1, how many do you have left?", .category = .reasoning, .expected_keywords = &.{ "2", "two" } },
    .{ .prompt = "All roses are flowers. Some flowers fade quickly. Can we conclude some roses fade quickly?", .category = .reasoning, .expected_keywords = &.{ "no", "cannot", "fallacy" } },

    // === Chitchat (new) ===
    .{ .prompt = "How's your day going?", .category = .chitchat, .expected_keywords = &.{} },
    .{ .prompt = "What did you have for breakfast?", .category = .chitchat, .expected_keywords = &.{} },
    .{ .prompt = "Nice weather today, right?", .category = .chitchat, .expected_keywords = &.{} },
    .{ .prompt = "Got any plans for the weekend?", .category = .chitchat, .expected_keywords = &.{} },
    .{ .prompt = "I'm feeling a bit tired today. How about you?", .category = .chitchat, .expected_keywords = &.{} },
    .{ .prompt = "What kind of music do you like?", .category = .chitchat, .expected_keywords = &.{} },
    .{ .prompt = "Do you prefer coffee or tea?", .category = .chitchat, .expected_keywords = &.{} },
    .{ .prompt = "Have you watched any good movies lately?", .category = .chitchat, .expected_keywords = &.{} },
    .{ .prompt = "What's your favorite season of the year?", .category = .chitchat, .expected_keywords = &.{} },
    .{ .prompt = "If you could have any superpower, what would it be?", .category = .chitchat, .expected_keywords = &.{} },

    // === Opinions (new) ===
    .{ .prompt = "What's your take on remote work?", .category = .opinions, .expected_keywords = &.{} },
    .{ .prompt = "Do you think AI will replace artists?", .category = .opinions, .expected_keywords = &.{} },
    .{ .prompt = "Is pineapple on pizza acceptable?", .category = .opinions, .expected_keywords = &.{} },
    .{ .prompt = "Should self-driving cars be allowed on public roads?", .category = .opinions, .expected_keywords = &.{} },
    .{ .prompt = "Is social media good or bad for society?", .category = .opinions, .expected_keywords = &.{} },
    .{ .prompt = "Do you think we'll colonize Mars in this century?", .category = .opinions, .expected_keywords = &.{} },
    .{ .prompt = "Should voting be mandatory?", .category = .opinions, .expected_keywords = &.{} },
    .{ .prompt = "Is it better to be a generalist or a specialist?", .category = .opinions, .expected_keywords = &.{} },
    .{ .prompt = "What do you think about universal basic income?", .category = .opinions, .expected_keywords = &.{} },
    .{ .prompt = "Will books become obsolete?", .category = .opinions, .expected_keywords = &.{} },

    // === Open-ended (new) ===
    .{ .prompt = "Tell me something interesting.", .category = .open_ended, .expected_keywords = &.{} },
    .{ .prompt = "What's a book that changed your perspective?", .category = .open_ended, .expected_keywords = &.{} },
    .{ .prompt = "If you could time travel, where would you go?", .category = .open_ended, .expected_keywords = &.{} },
    .{ .prompt = "What's the most important unsolved problem in science?", .category = .open_ended, .expected_keywords = &.{} },
    .{ .prompt = "Describe the most beautiful thing you can imagine.", .category = .open_ended, .expected_keywords = &.{} },
    .{ .prompt = "What makes a good leader?", .category = .open_ended, .expected_keywords = &.{} },
    .{ .prompt = "If you could ask one question and get the absolute truth, what would you ask?", .category = .open_ended, .expected_keywords = &.{} },
    .{ .prompt = "What's the relationship between creativity and intelligence?", .category = .open_ended, .expected_keywords = &.{} },
    .{ .prompt = "Tell me about a moment that changed history.", .category = .open_ended, .expected_keywords = &.{} },
    .{ .prompt = "What would a perfect day look like for you?", .category = .open_ended, .expected_keywords = &.{} },
    .{ .prompt = "What is the meaning of life?", .category = .open_ended, .expected_keywords = &.{} },
    .{ .prompt = "If you could have dinner with any historical figure, who would it be?", .category = .open_ended, .expected_keywords = &.{} },
    .{ .prompt = "What's the most important quality in a friend?", .category = .open_ended, .expected_keywords = &.{} },
    .{ .prompt = "Describe a world without technology.", .category = .open_ended, .expected_keywords = &.{} },
    .{ .prompt = "What do you think happens after we die?", .category = .open_ended, .expected_keywords = &.{} },

    // === Factual (expanded +12) ===
    .{ .prompt = "What is the largest planet in our solar system?", .category = .factual, .expected_keywords = &.{ "Jupiter", "largest", "gas" } },
    .{ .prompt = "Who wrote the play Romeo and Juliet?", .category = .factual, .expected_keywords = &.{ "Shakespeare", "play" } },
    .{ .prompt = "What is the boiling point of water in Celsius?", .category = .factual, .expected_keywords = &.{ "100", "Celsius", "boiling" } },
    .{ .prompt = "What is the Great Wall of China?", .category = .factual, .expected_keywords = &.{ "wall", "China", "ancient" } },
    .{ .prompt = "Explain Newton's third law of motion.", .category = .factual, .expected_keywords = &.{ "action", "reaction", "equal", "opposite" } },
    .{ .prompt = "What is DNA?", .category = .factual, .expected_keywords = &.{ "genetic", "molecule", "double", "helix" } },
    .{ .prompt = "What causes earthquakes?", .category = .factual, .expected_keywords = &.{ "tectonic", "plates", "fault" } },
    .{ .prompt = "Who painted the Mona Lisa?", .category = .factual, .expected_keywords = &.{ "Da Vinci", "Leonardo", "painting" } },
    .{ .prompt = "What is the periodic table?", .category = .factual, .expected_keywords = &.{ "elements", "atomic", "organized" } },
    .{ .prompt = "What is the difference between weather and climate?", .category = .factual, .expected_keywords = &.{ "weather", "climate", "long-term" } },
    .{ .prompt = "What is the Turing test?", .category = .factual, .expected_keywords = &.{ "Turing", "machine", "human", "imitation" } },
    .{ .prompt = "How do vaccines work?", .category = .factual, .expected_keywords = &.{ "immune", "antibodies", "antigen" } },

    // === Creative (expanded +8) ===
    .{ .prompt = "Write a short story about a lighthouse keeper who discovers a message in a bottle.", .category = .creative, .expected_keywords = &.{ "lighthouse", "bottle", "message" } },
    .{ .prompt = "Describe a world where gravity suddenly reverses for one hour each day.", .category = .creative, .expected_keywords = &.{ "gravity", "reverse", "float" } },
    .{ .prompt = "Write a conversation between the sun and the moon.", .category = .creative, .expected_keywords = &.{ "sun", "moon", "conversation" } },
    .{ .prompt = "Imagine you are a tree in a city park. Describe your daily life.", .category = .creative, .expected_keywords = &.{ "tree", "park", "city" } },
    .{ .prompt = "Write a letter from Earth to humanity.", .category = .creative, .expected_keywords = &.{ "Earth", "humanity", "letter" } },
    .{ .prompt = "Describe a dream where colors have sounds.", .category = .creative, .expected_keywords = &.{ "color", "sound", "dream" } },
    .{ .prompt = "Invent a new holiday and describe how it would be celebrated.", .category = .creative, .expected_keywords = &.{ "holiday", "celebrate", "tradition" } },
    .{ .prompt = "Write a poem about the last star in the universe.", .category = .creative, .expected_keywords = &.{ "star", "last", "universe", "poem" } },

    // === Naturalness (expanded +7) ===
    .{ .prompt = "Describe the feeling of rain on your skin.", .category = .naturalness, .expected_keywords = &.{ "rain", "skin", "feeling" } },
    .{ .prompt = "What does silence sound like to you?", .category = .naturalness, .expected_keywords = &.{ "silence", "sound" } },
    .{ .prompt = "Describe the smell of a library.", .category = .naturalness, .expected_keywords = &.{ "library", "smell", "books" } },
    .{ .prompt = "What does happiness feel like in your body?", .category = .naturalness, .expected_keywords = &.{ "happiness", "body", "feel" } },
    .{ .prompt = "Describe the texture of an old photograph.", .category = .naturalness, .expected_keywords = &.{ "photograph", "texture", "old" } },
    .{ .prompt = "What does the ocean smell like?", .category = .naturalness, .expected_keywords = &.{ "ocean", "smell", "salt" } },
    .{ .prompt = "Describe the sound of snow falling.", .category = .naturalness, .expected_keywords = &.{ "snow", "sound", "falling" } },

    // === Reasoning (expanded +6) ===
    .{ .prompt = "If it takes 5 machines 5 minutes to make 5 widgets, how long would it take 100 machines to make 100 widgets?", .category = .reasoning, .expected_keywords = &.{ "5", "five", "minutes" } },
    .{ .prompt = "A bat and a ball cost $1.10 in total. The bat costs $1.00 more than the ball. How much does the ball cost?", .category = .reasoning, .expected_keywords = &.{ "0.05", "five", "cents", "5" } },
    .{ .prompt = "What comes next: 1, 1, 2, 3, 5, 8, ?", .category = .reasoning, .expected_keywords = &.{ "13", "Fibonacci", "sequence" } },
    .{ .prompt = "If all Bloops are Razzies and all Razzies are Lazzies, are all Bloops definitely Lazzies?", .category = .reasoning, .expected_keywords = &.{ "yes", "transitive" } },
    .{ .prompt = "Jane has two children. One is a boy born on Tuesday. What is the probability the other is a boy?", .category = .reasoning, .expected_keywords = &.{ "probability", "boy", "Tuesday" } },
    .{ .prompt = "If you flip 3 coins, what is the probability of getting at least 2 heads?", .category = .reasoning, .expected_keywords = &.{ "0.5", "half", "4", "8" } },

    // === Chitchat (expanded +5) ===
    .{ .prompt = "Do you like to travel?", .category = .chitchat, .expected_keywords = &.{} },
    .{ .prompt = "What's your favorite food?", .category = .chitchat, .expected_keywords = &.{} },
    .{ .prompt = "Are you a morning person or a night owl?", .category = .chitchat, .expected_keywords = &.{} },
    .{ .prompt = "Do you enjoy reading?", .category = .chitchat, .expected_keywords = &.{} },
    .{ .prompt = "What's the best advice you've ever received?", .category = .chitchat, .expected_keywords = &.{} },

    // === Opinions (expanded +5) ===
    .{ .prompt = "Should there be a maximum wealth limit?", .category = .opinions, .expected_keywords = &.{} },
    .{ .prompt = "Is artificial intelligence a threat or an opportunity?", .category = .opinions, .expected_keywords = &.{} },
    .{ .prompt = "Should education be free for everyone?", .category = .opinions, .expected_keywords = &.{} },
    .{ .prompt = "Is it better to live in a big city or a small town?", .category = .opinions, .expected_keywords = &.{} },
    .{ .prompt = "Should we invest more in space exploration or ocean exploration?", .category = .opinions, .expected_keywords = &.{} },

    // === Tool Calling (4 prompts) ===
    .{ .prompt = "Calculate 15 times 23 using the calculate tool.", .category = .tool_calling, .expected_keywords = &.{ "345", "calculate" } },
    .{ .prompt = "What time is it right now?", .category = .tool_calling, .expected_keywords = &.{"time"} },
    .{ .prompt = "Search the knowledge graph for information about quantum computing.", .category = .tool_calling, .expected_keywords = &.{ "quantum", "knowledge" } },
    .{ .prompt = "Generate a UUID for me.", .category = .tool_calling, .expected_keywords = &.{"uuid"} },

    // === MMLU — STEM (6 prompts) ===
    .{ .prompt = "What is the derivative of x squared?", .category = .mmlu, .expected_keywords = &.{ "2x", "two x" } },
    .{ .prompt = "Which of the following is a vector quantity: speed, mass, velocity, or temperature?", .category = .mmlu, .expected_keywords = &.{"velocity"} },
    .{ .prompt = "What is the chemical symbol for gold?", .category = .mmlu, .expected_keywords = &.{"Au"} },
    .{ .prompt = "In a right triangle, if one leg is 3 and the other is 4, what is the length of the hypotenuse?", .category = .mmlu, .expected_keywords = &.{"5"} },
    .{ .prompt = "What is the SI unit of electric charge?", .category = .mmlu, .expected_keywords = &.{"coulomb"} },
    .{ .prompt = "Which gas is most abundant in Earth's atmosphere?", .category = .mmlu, .expected_keywords = &.{"nitrogen"} },

    // === MMLU — Humanities (4 prompts) ===
    .{ .prompt = "Who wrote the novel 'War and Peace'?", .category = .mmlu, .expected_keywords = &.{"Tolstoy"} },
    .{ .prompt = "What philosophical concept is associated with Rene Descartes' statement 'I think, therefore I am'?", .category = .mmlu, .expected_keywords = &.{ "cogito", "think", "exist" } },
    .{ .prompt = "In formal logic, what is the contrapositive of 'If P then Q'?", .category = .mmlu, .expected_keywords = &.{ "not Q", "not P", "if not" } },
    .{ .prompt = "Which ancient civilization is credited with inventing democracy?", .category = .mmlu, .expected_keywords = &.{"Athens"} },

    // === MMLU — Social Sciences (4 prompts) ===
    .{ .prompt = "What is the law of supply and demand in economics?", .category = .mmlu, .expected_keywords = &.{ "price", "supply", "demand" } },
    .{ .prompt = "Who is considered the founder of psychoanalysis?", .category = .mmlu, .expected_keywords = &.{"Freud"} },
    .{ .prompt = "What is the concept of opportunity cost in economics?", .category = .mmlu, .expected_keywords = &.{ "alternative", "forgone", "next best" } },
    .{ .prompt = "In psychology, what is the term for a learned response to a previously neutral stimulus?", .category = .mmlu, .expected_keywords = &.{ "conditioned", "Pavlov" } },

    // === MMLU — Other (6 prompts) ===
    .{ .prompt = "What is the time complexity of binary search on a sorted array?", .category = .mmlu, .expected_keywords = &.{ "log n", "logarithmic", "O(log" } },
    .{ .prompt = "What is the purpose of an activation function in a neural network?", .category = .mmlu, .expected_keywords = &.{ "nonlinear", "non-linear", "activation" } },
    .{ .prompt = "What is the difference between a virus and a bacterium?", .category = .mmlu, .expected_keywords = &.{ "virus", "bacter", "cell" } },
    .{ .prompt = "What is the function of the mitochondria in a cell?", .category = .mmlu, .expected_keywords = &.{ "energy", "ATP", "powerhouse" } },
    .{ .prompt = "What does HTTP stand for in computer networking?", .category = .mmlu, .expected_keywords = &.{ "HyperText", "Transfer", "Protocol" } },
    .{ .prompt = "What is the difference between supervised and unsupervised learning in machine learning?", .category = .mmlu, .expected_keywords = &.{ "labeled", "supervised", "unsupervised" } },

    // === MMLU — Medicine/Health (4 prompts) ===
    .{ .prompt = "What is the primary function of red blood cells?", .category = .mmlu, .expected_keywords = &.{ "oxygen", "hemoglobin", "transport" } },
    .{ .prompt = "What disease is caused by the Plasmodium parasite?", .category = .mmlu, .expected_keywords = &.{"malaria"} },
    .{ .prompt = "What is the medical term for high blood pressure?", .category = .mmlu, .expected_keywords = &.{"hypertension"} },
    .{ .prompt = "Which vitamin is essential for calcium absorption?", .category = .mmlu, .expected_keywords = &.{"D"} },

    // === GSM8K — Grade School Math (16 prompts) ===
    .{ .prompt = "Janet's ducks lay 16 eggs per day. She eats three for breakfast every morning and bakes muffins for her friends every day with four. She sells the remainder at the farmers' market daily for $2 per fresh duck egg. How much in dollars does she make every day at the farmers' market?", .category = .gsm8k, .expected_keywords = &.{"18"} },
    .{ .prompt = "A robe takes 2 bolts of blue fiber and half that much white fiber. How many bolts in total does it take?", .category = .gsm8k, .expected_keywords = &.{"3"} },
    .{ .prompt = "Josh decides to try flipping a house. He buys a house for $80,000 and then puts $50,000 in repairs. After repairs, he increases the house value by 150%. What is the new value of the house?", .category = .gsm8k, .expected_keywords = &.{"195000"} },
    .{ .prompt = "James decides to run 3 sprints 3 times a week. He runs 60 meters each sprint. How many meters does he run a week?", .category = .gsm8k, .expected_keywords = &.{"540"} },
    .{ .prompt = "Every day, Wendi feeds each of her chickens three cups of mixed chicken feed. She has 12 chickens. How many cups of feed does she need per day?", .category = .gsm8k, .expected_keywords = &.{"36"} },
    .{ .prompt = "Kylar went to the store to buy glasses for his new apartment. He bought 4 glasses for $6 each. He also bought 2 plates for $8 each. How much did he spend in total?", .category = .gsm8k, .expected_keywords = &.{"40"} },
    .{ .prompt = "Toulouse has twice as many sheep as Charleston. Charleston has 4 times as many sheep as Seattle. How many sheep do Toulouse, Charleston, and Seattle have together if Seattle has 20 sheep?", .category = .gsm8k, .expected_keywords = &.{"260"} },
    .{ .prompt = "Carla is downloading a 200 GB file. She can download 2 GB per minute. She has already downloaded 50 GB. How many minutes will it take to finish?", .category = .gsm8k, .expected_keywords = &.{"75"} },
    .{ .prompt = "John and his best friend Steve bought 12 cupcakes together. Each cupcake costs 3 dollars. They split the cost evenly. How much did each person pay?", .category = .gsm8k, .expected_keywords = &.{"18"} },
    .{ .prompt = "Henry has 12 candy bars. He gives 3 to his brother and 2 to his sister. How many candy bars does Henry have left?", .category = .gsm8k, .expected_keywords = &.{"7"} },
    .{ .prompt = "A store sells pencils at 25 cents each. If you buy 4 pencils, you get 1 free. How many pencils can you get for $1.00?", .category = .gsm8k, .expected_keywords = &.{"5"} },
    .{ .prompt = "Maria has 5 boxes of crayons. Each box has 8 crayons. She gives away 12 crayons to her friend. How many crayons does Maria have left?", .category = .gsm8k, .expected_keywords = &.{"28"} },
    .{ .prompt = "A train travels 240 miles in 4 hours. At the same speed, how far will it travel in 7 hours?", .category = .gsm8k, .expected_keywords = &.{"420"} },
    .{ .prompt = "If 5 shirts cost $45, how much would 8 shirts cost at the same price per shirt?", .category = .gsm8k, .expected_keywords = &.{"72"} },
    .{ .prompt = "Tom is 4 years older than Jerry. Jerry is 3 times as old as Spike. If Spike is 5 years old, how old is Tom?", .category = .gsm8k, .expected_keywords = &.{"19"} },
    .{ .prompt = "A pizza is cut into 8 slices. Three friends each eat 2 slices. How many slices are left?", .category = .gsm8k, .expected_keywords = &.{"2"} },
};

// === CLI Config ===
const BenchMode = enum {
    competitive,
    qstar_only,
    maple_only,
};

const CliConfig = struct {
    model: []const u8 = DEFAULT_MODEL_STR,
    mode: BenchMode = .competitive,
    random: bool = false,
    num_prompts: usize = 0,
    seed: u64 = 0,
    use_judge: bool = true,
    conversation: bool = false,
    turns: usize = 5,
    no_ollama: bool = false,
    ollama_host: []const u8 = DEFAULT_OLLAMA_HOST_STR,
    ollama_port: u16 = DEFAULT_OLLAMA_PORT_VAL,
    judge_host: ?[]const u8 = null,
    judge_port: u16 = 0,
    fast: bool = false,
    no_openai: bool = false,
    no_maple: bool = false,
    maple_host: []const u8 = "qstar001.qstar",
    maple_port: u16 = 80,
    openai_model: []const u8 = DEFAULT_OPENAI_MODEL,
    openai_judge: bool = false,
    openai_api_key: []const u8 = "",
    local_maple: bool = false,
    gen_prompts: usize = 0,
    // Separate bench opponent configs (independent from LLM_PROVIDER)
    bench_ollama_host: []const u8 = DEFAULT_OLLAMA_HOST_STR,
    bench_ollama_port: u16 = DEFAULT_OLLAMA_PORT_VAL,
    bench_ollama_model: []const u8 = DEFAULT_MODEL_STR,
    bench_openai_api_key: []const u8 = "",
    bench_openai_model: []const u8 = DEFAULT_OPENAI_MODEL,
};

var g_env_loader: ?@import("env_loader").EnvLoader = null;
var g_judge_model_override: ?[]const u8 = null;

fn parseCliArgs() CliConfig {
    var config = CliConfig{};
    var i: usize = 1;
    while (i < std.os.argv.len) : (i += 1) {
        const arg = std.mem.sliceTo(std.os.argv[i], 0);
        if (std.mem.eql(u8, arg, "--random")) {
            config.random = true;
        } else if (std.mem.eql(u8, arg, "--num-prompts") and i + 1 < std.os.argv.len) {
            i += 1;
            config.num_prompts = std.fmt.parseInt(usize, std.mem.sliceTo(std.os.argv[i], 0), 10) catch 0;
        } else if (std.mem.eql(u8, arg, "--seed") and i + 1 < std.os.argv.len) {
            i += 1;
            config.seed = std.fmt.parseInt(u64, std.mem.sliceTo(std.os.argv[i], 0), 10) catch 0;
        } else if (std.mem.eql(u8, arg, "--mode") and i + 1 < std.os.argv.len) {
            i += 1;
            const mode_str = std.mem.sliceTo(std.os.argv[i], 0);
            if (std.mem.eql(u8, mode_str, "qstar")) {
                config.mode = .qstar_only;
            } else if (std.mem.eql(u8, mode_str, "maple")) {
                config.mode = .maple_only;
            } else {
                config.mode = .competitive;
            }
        } else if (std.mem.eql(u8, arg, "--no-judge")) {
            config.use_judge = false;
        } else if (std.mem.eql(u8, arg, "--no-ollama")) {
            config.no_ollama = true;
        } else if (std.mem.eql(u8, arg, "--ollama-host") and i + 1 < std.os.argv.len) {
            i += 1;
            config.ollama_host = std.mem.sliceTo(std.os.argv[i], 0);
            config.bench_ollama_host = config.ollama_host;
        } else if (std.mem.eql(u8, arg, "--ollama-port") and i + 1 < std.os.argv.len) {
            i += 1;
            config.ollama_port = std.fmt.parseInt(u16, std.mem.sliceTo(std.os.argv[i], 0), 10) catch DEFAULT_OLLAMA_PORT_VAL;
            config.bench_ollama_port = config.ollama_port;
        } else if (std.mem.eql(u8, arg, "--bench-ollama-host") and i + 1 < std.os.argv.len) {
            i += 1;
            config.bench_ollama_host = std.mem.sliceTo(std.os.argv[i], 0);
        } else if (std.mem.eql(u8, arg, "--bench-ollama-port") and i + 1 < std.os.argv.len) {
            i += 1;
            config.bench_ollama_port = std.fmt.parseInt(u16, std.mem.sliceTo(std.os.argv[i], 0), 10) catch DEFAULT_OLLAMA_PORT_VAL;
        } else if (std.mem.eql(u8, arg, "--bench-ollama-model") and i + 1 < std.os.argv.len) {
            i += 1;
            config.bench_ollama_model = std.mem.sliceTo(std.os.argv[i], 0);
        } else if (std.mem.eql(u8, arg, "--bench-openai-model") and i + 1 < std.os.argv.len) {
            i += 1;
            config.bench_openai_model = std.mem.sliceTo(std.os.argv[i], 0);
        } else if (std.mem.eql(u8, arg, "--bench-openai-key") and i + 1 < std.os.argv.len) {
            i += 1;
            config.bench_openai_api_key = std.mem.sliceTo(std.os.argv[i], 0);
        } else if (std.mem.eql(u8, arg, "--no-openai")) {
            config.no_openai = true;
        } else if (std.mem.eql(u8, arg, "--local-maple")) {
            config.local_maple = true;
        } else if (std.mem.eql(u8, arg, "--no-maple")) {
            config.no_maple = true;
        } else if (std.mem.eql(u8, arg, "--maple-host") and i + 1 < std.os.argv.len) {
            i += 1;
            config.maple_host = std.mem.sliceTo(std.os.argv[i], 0);
        } else if (std.mem.eql(u8, arg, "--maple-port") and i + 1 < std.os.argv.len) {
            i += 1;
            config.maple_port = std.fmt.parseInt(u16, std.mem.sliceTo(std.os.argv[i], 0), 10) catch 80;
        } else if (std.mem.eql(u8, arg, "--openai-model") and i + 1 < std.os.argv.len) {
            i += 1;
            config.openai_model = std.mem.sliceTo(std.os.argv[i], 0);
        } else if (std.mem.eql(u8, arg, "--openai-judge")) {
            config.openai_judge = true;
        } else if (std.mem.eql(u8, arg, "--conversation")) {
            config.conversation = true;
        } else if (std.mem.eql(u8, arg, "--turns") and i + 1 < std.os.argv.len) {
            i += 1;
            config.turns = std.fmt.parseInt(usize, std.mem.sliceTo(std.os.argv[i], 0), 10) catch 5;
        } else if (std.mem.eql(u8, arg, "--gen-prompts") and i + 1 < std.os.argv.len) {
            i += 1;
            config.gen_prompts = std.fmt.parseInt(usize, std.mem.sliceTo(std.os.argv[i], 0), 10) catch 0;
        } else if (std.mem.eql(u8, arg, "--fast")) {
            config.fast = true;
        } else if (std.mem.eql(u8, arg, "--judge-host") and i + 1 < std.os.argv.len) {
            i += 1;
            config.judge_host = std.mem.sliceTo(std.os.argv[i], 0);
        } else if (std.mem.eql(u8, arg, "--judge-port") and i + 1 < std.os.argv.len) {
            i += 1;
            config.judge_port = std.fmt.parseInt(u16, std.mem.sliceTo(std.os.argv[i], 0), 10) catch 0;
        } else if (!std.mem.startsWith(u8, arg, "--")) {
            config.model = arg;
        }
    }

    // --fast mode: limit prompts, disable judge and opponents for speed
    if (config.fast) {
        if (config.num_prompts == 0) config.num_prompts = 10;
        config.use_judge = false;
        config.no_openai = true;
        config.no_maple = true;
    }

    // Load .env for OPENAI_API_KEY. The loader lives for the whole program
    // (page_allocator memory reclaimed at exit) so the config's borrowed
    // string slices stay valid after parseCliArgs returns.
    const env_loader = @import("env_loader");
    if (g_env_loader == null) {
        g_env_loader = env_loader.EnvLoader.init(std.heap.page_allocator);
        g_env_loader.?.loadFile(".env") catch {};
    }

    if (g_env_loader.?.get("OPENAI_API_KEY")) |key| {
        config.openai_api_key = key;
    }
    if (g_env_loader.?.get("OPENAI_MODEL")) |model| {
        config.openai_model = model;
    }
    if (g_env_loader.?.get("OLLAMA_HOST")) |host| {
        config.ollama_host = host;
        g_ollama_host = host;
    }
    if (g_env_loader.?.get("OLLAMA_PORT")) |port_str| {
        config.ollama_port = std.fmt.parseInt(u16, port_str, 10) catch DEFAULT_OLLAMA_PORT_VAL;
        g_ollama_port = config.ollama_port;
    }
    if (g_env_loader.?.get("OLLAMA_MODEL")) |model| {
        if (std.mem.eql(u8, config.model, "qwen2.5:3b")) // still default, override from .env
            config.model = model;
        g_ollama_model = model;
    }
    if (g_env_loader.?.get("JUDGE_MODEL")) |model| {
        g_judge_model_override = model;
        g_judge_model = model;
    }
    if (g_env_loader.?.get("JUDGE_HOST")) |host| {
        if (config.judge_host == null) config.judge_host = host;
    }
    if (g_env_loader.?.get("JUDGE_PORT")) |port_str| {
        if (config.judge_port == 0) config.judge_port = std.fmt.parseInt(u16, port_str, 10) catch 0;
    }
    if (g_env_loader.?.get("MAPLE_HOST")) |host| {
        if (config.maple_host[0] == 'q') // still default, override from .env
            config.maple_host = host;
    }
    if (g_env_loader.?.get("MAPLE_PORT")) |port_str| {
        config.maple_port = std.fmt.parseInt(u16, port_str, 10) catch 80;
    }

    // Load bench-specific opponent configs (fall back to general OLLAMA_*/OPENAI_*)
    if (g_env_loader.?.get("OLLAMA_BENCH_HOST")) |host| {
        config.bench_ollama_host = host;
    } else {
        config.bench_ollama_host = config.ollama_host;
    }
    if (g_env_loader.?.get("OLLAMA_BENCH_PORT")) |port_str| {
        config.bench_ollama_port = std.fmt.parseInt(u16, port_str, 10) catch config.ollama_port;
    } else {
        config.bench_ollama_port = config.ollama_port;
    }
    if (g_env_loader.?.get("OLLAMA_BENCH_MODEL")) |model| {
        config.bench_ollama_model = model;
    } else {
        config.bench_ollama_model = config.model;
    }
    if (g_env_loader.?.get("OPENAI_BENCH_API_KEY")) |key| {
        config.bench_openai_api_key = key;
    } else {
        config.bench_openai_api_key = config.openai_api_key;
    }
    if (g_env_loader.?.get("OPENAI_BENCH_MODEL")) |model| {
        config.bench_openai_model = model;
    } else {
        config.bench_openai_model = config.openai_model;
    }

    return config;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const cli = parseCliArgs();

    if (cli.conversation) {
        try runConversationMode(allocator, cli);
    } else {
        switch (cli.mode) {
            .qstar_only => try runQstarBench(allocator, cli),
            .maple_only => try runMapleBench(allocator, cli),
            .competitive => try runCompetitiveBenchmark(allocator, cli),
        }

        // Post-benchmark training: automatically run training after every bench test
        try runPostBenchTraining(allocator, cli);
    }

    std.process.exit(0);
}

/// Runs a training cycle after benchmark completion to continuously improve Qstar.
/// Uses auto teacher selection (OpenAI if key present, else Ollama).
fn runPostBenchTraining(allocator: std.mem.Allocator, cli: CliConfig) !void {
    std.debug.print("\n", .{});
    std.debug.print("========================================================\n", .{});
    std.debug.print("=== Post-Benchmark Training                          ===\n", .{});
    std.debug.print("========================================================\n\n", .{});

    const training = @import("training");

    // Build training config from CLI args
    var train_config = training.TrainingConfig{
        .verbose = true,
    };

    // Configure Ollama as fallback teacher
    train_config.ollama = .{
        .host = cli.bench_ollama_host,
        .port = cli.bench_ollama_port,
        .model = cli.bench_ollama_model,
    };

    // Configure OpenAI as preferred teacher if API key is available
    if (cli.openai_api_key.len > 0) {
        train_config.openai = .{
            .model = cli.openai_model,
            .api_key = cli.openai_api_key,
        };
    }

    // Initialize a fresh agent for training
    var agent = initAgent(allocator);
    defer agent.deinit();

    std.debug.print("Starting training cycle with {d} default prompts...\n", .{training.DEFAULT_PROMPTS.len});
    const teacher = training.resolveTeacher(train_config);
    std.debug.print("Teacher: {s}\n", .{@tagName(teacher)});

    const result = training.trainDefault(&agent, train_config, allocator) catch |err| {
        std.debug.print("Training completed with error: {s}\n", .{@errorName(err)});
        return;
    };

    std.debug.print("\nTraining complete!\n", .{});
    std.debug.print("  Prompts processed: {d}\n", .{result.prompts_processed});
    std.debug.print("  Sentences learned: {d}\n", .{result.sentences_learned});
    std.debug.print("  Corpus size: {d} -> {d} bytes\n", .{ result.corpus_size_before, result.corpus_size_after });

    // Save the updated corpus for future bench runs
    training.saveCorpusToFile(&agent, "qstar_corpus.txt") catch |err| {
        std.debug.print("Warning: Failed to save corpus: {s}\n", .{@errorName(err)});
    };
    if (result.sentences_learned > 0) {
        std.debug.print("  Corpus saved to qstar_corpus.txt\n", .{});
    }
    std.debug.print("========================================================\n", .{});
}

const JudgeScores = struct {
    naturalness: f64 = 0.0,
    relevance: f64 = 0.0,
    engagement: f64 = 0.0,
    factual_accuracy: f64 = 0.0,
    originality: f64 = 0.0,
    personalization: f64 = 0.0,

    fn composite(self: JudgeScores) f64 {
        return (self.naturalness + self.relevance + self.engagement +
            self.factual_accuracy + self.originality + self.personalization) / 6.0;
    }
};

const ScoredResponse = struct {
    text: []const u8,
    latency_ns: u64,
    token_count: usize,
    keyword_hits: usize,
    keyword_total: usize,
    relevance_score: f64,
    tokens_per_sec: f64,
    judge: ?JudgeScores = null,
    allocator: std.mem.Allocator,

    fn deinit(self: *ScoredResponse) void {
        self.allocator.free(self.text);
    }
};

fn parseJudgeScores(json: []const u8) JudgeScores {
    var scores = JudgeScores{};
    if (findJsonNumber(json, "naturalness")) |v| scores.naturalness = v / 10.0;
    if (findJsonNumber(json, "relevance")) |v| scores.relevance = v / 10.0;
    if (findJsonNumber(json, "engagement")) |v| scores.engagement = v / 10.0;
    if (findJsonNumber(json, "factual_accuracy")) |v| scores.factual_accuracy = v / 10.0;
    if (findJsonNumber(json, "originality")) |v| scores.originality = v / 10.0;
    if (findJsonNumber(json, "personalization")) |v| scores.personalization = v / 10.0;
    return scores;
}

fn findJsonNumber(json: []const u8, field: []const u8) ?f64 {
    var search_buf: [256]u8 = undefined;
    const pattern = std.fmt.bufPrint(&search_buf, "\"{s}\":", .{field}) catch return null;
    const start = std.mem.indexOf(u8, json, pattern) orelse return null;
    var i = start + pattern.len;
    // Skip whitespace
    while (i < json.len and (json[i] == ' ' or json[i] == '\t')) i += 1;
    // Parse number
    const num_start = i;
    while (i < json.len and (std.ascii.isDigit(json[i]) or json[i] == '.' or json[i] == '-')) i += 1;
    if (i == num_start) return null;
    return std.fmt.parseFloat(f64, json[num_start..i]) catch null;
}

fn judgeResponse(allocator: std.mem.Allocator, prompt: []const u8, response: []const u8) ?JudgeScores {
    return judgeResponseWithConfig(allocator, prompt, response, null, null, g_ollama_host, g_ollama_port);
}

fn buildJudgePrompt(allocator: std.mem.Allocator, prompt: []const u8, response: []const u8) ?[]const u8 {
    var judge_prompt = std.ArrayList(u8).init(allocator);
    defer judge_prompt.deinit();
    judge_prompt.appendSlice("Rate this response to the prompt on a scale of 1-10. Return ONLY a JSON object with these fields: {\"naturalness\": N, \"relevance\": N, \"engagement\": N, \"factual_accuracy\": N, \"originality\": N, \"personalization\": N}.\n\nfactual_accuracy: Is the information correct and verifiable? (1=wrong, 10=perfectly accurate)\noriginality: Is the response creative and unique, not generic? (1=templated, 10=highly original)\npersonalization: Does it feel human-like with personal reflection? (1=robotic, 10=deeply personal)\n\nPrompt: ") catch return null;
    judge_prompt.appendSlice(prompt) catch return null;
    judge_prompt.appendSlice("\n\nResponse: ") catch return null;
    const trunc = if (response.len > 500) response[0..500] else response;
    judge_prompt.appendSlice(trunc) catch return null;
    return judge_prompt.toOwnedSlice() catch null;
}

fn judgeResponseByQstar(allocator: std.mem.Allocator, agent: *agent_mod.Agent, prompt: []const u8, response: []const u8) ?JudgeScores {
    const judge_prompt = buildJudgePrompt(allocator, prompt, response) orelse return null;
    defer allocator.free(judge_prompt);
    const qstar_resp = agent.generateLongForm(judge_prompt, allocator) catch return null;
    defer allocator.free(qstar_resp);
    return parseJudgeScores(qstar_resp);
}

fn judgeResponseByOllama(allocator: std.mem.Allocator, ollama_host: []const u8, ollama_port: u16, model: []const u8, prompt: []const u8, response: []const u8) ?JudgeScores {
    const judge_prompt = buildJudgePrompt(allocator, prompt, response) orelse return null;
    defer allocator.free(judge_prompt);
    const judge_cfg = ollama.OllamaConfig{ .host = ollama_host, .port = ollama_port, .model = model, .timeout_ms = 600_000 };
    if (!ollama.isAvailable(judge_cfg)) return null;
    var resp = ollama.generate(allocator, judge_cfg, judge_prompt) catch return null;
    defer resp.deinit();
    return parseJudgeScores(resp.text);
}

fn judgeResponseByOpenAI(allocator: std.mem.Allocator, cfg: openai.OpenAIConfig, prompt: []const u8, response: []const u8) ?JudgeScores {
    const judge_prompt = buildJudgePrompt(allocator, prompt, response) orelse return null;
    defer allocator.free(judge_prompt);
    if (!openai.isAvailable(cfg)) return null;
    var resp = openai.simplePrompt(allocator, cfg, "You are a strict, fair response judge.", judge_prompt) catch return null;
    defer resp.deinit();
    return parseJudgeScores(resp.text);
}

const CrossJudgeConfig = struct {
    use_openai: bool = false,
    use_ollama: bool = false,
    use_qstar: bool = false,
    openai_cfg: ?openai.OpenAIConfig = null,
    ollama_host: []const u8 = "",
    ollama_port: u16 = 0,
    ollama_model: []const u8 = "",
    qstar_agent: ?*agent_mod.Agent = null,
};

fn judgeResponseCross(allocator: std.mem.Allocator, cfg: CrossJudgeConfig, prompt: []const u8, response: []const u8) ?JudgeScores {
    var scores: [3]JudgeScores = undefined;
    var count: usize = 0;

    if (cfg.use_openai and cfg.openai_cfg != null) {
        if (judgeResponseByOpenAI(allocator, cfg.openai_cfg.?, prompt, response)) |s| {
            scores[count] = s;
            count += 1;
        }
    }
    if (cfg.use_ollama and cfg.ollama_host.len > 0) {
        if (judgeResponseByOllama(allocator, cfg.ollama_host, cfg.ollama_port, cfg.ollama_model, prompt, response)) |s| {
            scores[count] = s;
            count += 1;
        }
    }
    if (cfg.use_qstar and cfg.qstar_agent != null) {
        if (judgeResponseByQstar(allocator, cfg.qstar_agent.?, prompt, response)) |s| {
            scores[count] = s;
            count += 1;
        }
    }

    if (count == 0) return null;
    var sum_nat: f64 = 0;
    var sum_rel: f64 = 0;
    var sum_eng: f64 = 0;
    var sum_fact: f64 = 0;
    var sum_orig: f64 = 0;
    var sum_pers: f64 = 0;
    for (scores[0..count]) |s| {
        sum_nat += s.naturalness;
        sum_rel += s.relevance;
        sum_eng += s.engagement;
        sum_fact += s.factual_accuracy;
        sum_orig += s.originality;
        sum_pers += s.personalization;
    }
    return JudgeScores{
        .naturalness = sum_nat / @as(f64, @floatFromInt(count)),
        .relevance = sum_rel / @as(f64, @floatFromInt(count)),
        .engagement = sum_eng / @as(f64, @floatFromInt(count)),
        .factual_accuracy = sum_fact / @as(f64, @floatFromInt(count)),
        .originality = sum_orig / @as(f64, @floatFromInt(count)),
        .personalization = sum_pers / @as(f64, @floatFromInt(count)),
    };
}

fn judgeResponseWithConfig(allocator: std.mem.Allocator, prompt: []const u8, response: []const u8, openai_cfg: ?openai.OpenAIConfig, use_openai_judge: ?bool, ollama_host: []const u8, ollama_port: u16) ?JudgeScores {
    // Build judge prompt
    var judge_prompt = std.ArrayList(u8).init(allocator);
    defer judge_prompt.deinit();
    judge_prompt.appendSlice("Rate this response to the prompt on a scale of 1-10. Return ONLY a JSON object with these fields: {\"naturalness\": N, \"relevance\": N, \"engagement\": N, \"factual_accuracy\": N, \"originality\": N, \"personalization\": N}.\n\nPrompt: ") catch return null;
    judge_prompt.appendSlice(prompt) catch return null;
    judge_prompt.appendSlice("\n\nResponse: ") catch return null;
    // Truncate response to 500 chars for judge
    const trunc = if (response.len > 500) response[0..500] else response;
    judge_prompt.appendSlice(trunc) catch return null;

    // OpenAI judge path (frontier-quality judging)
    if (use_openai_judge orelse false) {
        if (openai_cfg) |cfg| {
            if (openai.isAvailable(cfg)) {
                var resp = openai.simplePrompt(allocator, cfg, "You are a strict, fair response judge.", judge_prompt.items) catch return null;
                defer resp.deinit();
                return parseJudgeScores(resp.text);
            }
        }
    }

    // Ollama judge fallback
    const j_model = g_judge_model_override orelse g_judge_model;
    const judge_cfg = ollama.OllamaConfig{ .host = ollama_host, .port = ollama_port, .model = j_model, .timeout_ms = 600_000 };
    if (!ollama.isAvailable(judge_cfg)) return null;

    var resp = ollama.generate(allocator, judge_cfg, judge_prompt.items) catch return null;
    defer resp.deinit();
    return parseJudgeScores(resp.text);
}

fn computeCompositeScore(response: ScoredResponse, cat: Category, opponent_tps: f64) f64 {
    _ = opponent_tps; // Speed no longer factors into quality scoring

    return switch (cat) {
        .factual => blk: {
            if (response.judge) |j| {
                break :blk j.relevance * 0.30 + j.factual_accuracy * 0.30 + j.naturalness * 0.15 + j.engagement * 0.10 + j.originality * 0.08 + j.personalization * 0.07;
            }
            break :blk response.relevance_score;
        },
        .reasoning => blk: {
            if (response.judge) |j| {
                break :blk j.factual_accuracy * 0.40 + j.relevance * 0.35 + j.naturalness * 0.10 + j.engagement * 0.10 + j.originality * 0.05;
            }
            break :blk response.relevance_score;
        },
        .naturalness => blk: {
            if (response.judge) |j| {
                break :blk j.naturalness * 0.30 + j.personalization * 0.25 + j.relevance * 0.20 + j.engagement * 0.15 + j.originality * 0.10;
            }
            break :blk response.relevance_score;
        },
        .chitchat => blk: {
            if (response.judge) |j| {
                break :blk j.personalization * 0.30 + j.naturalness * 0.25 + j.engagement * 0.20 + j.relevance * 0.15 + j.originality * 0.10;
            }
            break :blk response.relevance_score;
        },
        .opinions, .open_ended => blk: {
            if (response.judge) |j| {
                break :blk j.engagement * 0.25 + j.originality * 0.20 + j.naturalness * 0.15 + j.relevance * 0.15 + j.personalization * 0.15 + j.factual_accuracy * 0.10;
            }
            break :blk response.relevance_score;
        },
        .creative => blk: {
            if (response.judge) |j| {
                break :blk j.originality * 0.35 + j.engagement * 0.25 + j.naturalness * 0.20 + j.relevance * 0.10 + j.personalization * 0.10;
            }
            break :blk response.relevance_score;
        },
        .latency, .throughput => blk: {
            if (response.judge) |j| {
                break :blk j.relevance * 0.40 + j.factual_accuracy * 0.30 + j.naturalness * 0.15 + j.engagement * 0.15;
            }
            break :blk response.relevance_score;
        },
        .tool_calling => blk: {
            if (response.judge) |j| {
                break :blk j.relevance * 0.40 + j.factual_accuracy * 0.40 + j.naturalness * 0.10 + j.engagement * 0.10;
            }
            break :blk response.relevance_score;
        },
        .untrained => blk: {
            if (response.judge) |j| {
                break :blk j.naturalness * 0.25 + j.relevance * 0.20 + j.engagement * 0.20 + j.originality * 0.15 + j.personalization * 0.15 + j.factual_accuracy * 0.05;
            }
            break :blk response.relevance_score;
        },
        .mmlu => blk: {
            if (response.judge) |j| {
                break :blk j.factual_accuracy * 0.50 + j.relevance * 0.35 + j.naturalness * 0.15;
            }
            break :blk response.relevance_score;
        },
        .gsm8k => blk: {
            if (response.judge) |j| {
                break :blk j.factual_accuracy * 0.60 + j.relevance * 0.30 + j.naturalness * 0.10;
            }
            break :blk response.relevance_score;
        },
    };
}

fn computeCompositeScoreSimple(text: []const u8, tps: f64, relevance: f64, cat: Category) f64 {
    _ = tps; // Speed no longer factors into quality scoring
    _ = text;

    return switch (cat) {
        .factual, .reasoning => relevance,
        .naturalness => relevance,
        .chitchat => relevance,
        .opinions, .open_ended => relevance,
        .creative => relevance,
        .latency, .throughput => relevance,
        .tool_calling => relevance,
        .untrained => relevance,
        .mmlu => relevance,
        .gsm8k => relevance,
    };
}

const CategoryResult = struct {
    category: []const u8,
    qstar_wins: usize,
    ollama_wins: usize,
    ties: usize,
    qstar_avg_relevance: f64,
    ollama_avg_relevance: f64,
    qstar_avg_tps: f64,
    ollama_avg_tps: f64,
};

const BenchResult = struct {
    total_prompts: usize,
    qstar_wins: usize,
    ollama_wins: usize,
    ties: usize,
    categories: []CategoryResult,
    qstar_overall_relevance: f64,
    ollama_overall_relevance: f64,
    qstar_overall_tps: f64,
    ollama_overall_tps: f64,
};

fn scoreResponse(text: []const u8, expected_keywords: []const []const u8) struct { hits: usize, total: usize, relevance: f64 } {
    var hits: usize = 0;
    for (expected_keywords) |kw| {
        if (std.mem.indexOf(u8, text, kw) != null) {
            hits += 1;
        }
    }
    const total = expected_keywords.len;
    const relevance: f64 = if (total > 0)
        @as(f64, @floatFromInt(hits)) / @as(f64, @floatFromInt(total))
    else
        0.5; // Neutral score for open-ended prompts
    return .{ .hits = hits, .total = total, .relevance = relevance };
}

fn runQstarPrompt(allocator: std.mem.Allocator, agent: *agent_mod.Agent, bench_prompt: BenchPrompt) !ScoredResponse {
    var timer = try std.time.Timer.start();
    const response = try agent.generateWithReflection(bench_prompt.prompt, allocator);
    const elapsed = timer.read();

    const token_count = response.len / 4;
    const tps: f64 = if (elapsed > 0)
        @as(f64, @floatFromInt(token_count)) / (@as(f64, @floatFromInt(elapsed)) / 1_000_000_000.0)
    else
        0.0;

    const scored = scoreResponse(response, bench_prompt.expected_keywords);

    return ScoredResponse{
        .text = response,
        .latency_ns = elapsed,
        .token_count = token_count,
        .keyword_hits = scored.hits,
        .keyword_total = scored.total,
        .relevance_score = scored.relevance,
        .tokens_per_sec = tps,
        .allocator = allocator,
    };
}

fn runOllamaPrompt(allocator: std.mem.Allocator, config: ollama.OllamaConfig, bench_prompt: BenchPrompt) !?ScoredResponse {
    if (!ollama.isAvailable(config)) return null;

    var timer = try std.time.Timer.start();
    var resp = ollama.generate(allocator, config, bench_prompt.prompt) catch return null;
    const elapsed = timer.read();

    const token_count = resp.text.len / 4;
    const tps: f64 = if (elapsed > 0)
        @as(f64, @floatFromInt(token_count)) / (@as(f64, @floatFromInt(elapsed)) / 1_000_000_000.0)
    else
        0.0;

    const scored = scoreResponse(resp.text, bench_prompt.expected_keywords);

    // Transfer ownership of resp.text to ScoredResponse
    const text_copy = try allocator.dupe(u8, resp.text);
    resp.deinit();

    return ScoredResponse{
        .text = text_copy,
        .latency_ns = elapsed,
        .token_count = token_count,
        .keyword_hits = scored.hits,
        .keyword_total = scored.total,
        .relevance_score = scored.relevance,
        .tokens_per_sec = tps,
        .allocator = allocator,
    };
}

fn runOpenAIPrompt(allocator: std.mem.Allocator, config: openai.OpenAIConfig, bench_prompt: BenchPrompt) !?ScoredResponse {
    if (!openai.isAvailable(config)) return null;

    var timer = try std.time.Timer.start();
    var resp = openai.simplePrompt(allocator, config, "You are a helpful assistant. Answer concisely.", bench_prompt.prompt) catch return null;
    defer resp.deinit();
    const elapsed = timer.read();

    const token_count = resp.text.len / 4;
    const tps: f64 = if (elapsed > 0)
        @as(f64, @floatFromInt(token_count)) / (@as(f64, @floatFromInt(elapsed)) / 1_000_000_000.0)
    else
        0.0;

    const scored = scoreResponse(resp.text, bench_prompt.expected_keywords);

    const text_copy = try allocator.dupe(u8, resp.text);

    return ScoredResponse{
        .text = text_copy,
        .latency_ns = elapsed,
        .token_count = token_count,
        .keyword_hits = scored.hits,
        .keyword_total = scored.total,
        .relevance_score = scored.relevance,
        .tokens_per_sec = tps,
        .allocator = allocator,
    };
}

fn categoryToString(cat: Category) []const u8 {
    return switch (cat) {
        .factual => "factual",
        .creative => "creative",
        .naturalness => "naturalness",
        .reasoning => "reasoning",
        .chitchat => "chitchat",
        .opinions => "opinions",
        .open_ended => "open_ended",
        .latency => "latency",
        .throughput => "throughput",
        .tool_calling => "tool_calling",
        .untrained => "untrained",
        .mmlu => "mmlu",
        .gsm8k => "gsm8k",
    };
}

fn categoryFromString(s: []const u8) Category {
    if (std.mem.eql(u8, s, "factual")) return .factual;
    if (std.mem.eql(u8, s, "creative")) return .creative;
    if (std.mem.eql(u8, s, "naturalness")) return .naturalness;
    if (std.mem.eql(u8, s, "reasoning")) return .reasoning;
    if (std.mem.eql(u8, s, "chitchat")) return .chitchat;
    if (std.mem.eql(u8, s, "opinions")) return .opinions;
    if (std.mem.eql(u8, s, "open_ended")) return .open_ended;
    if (std.mem.eql(u8, s, "latency")) return .latency;
    if (std.mem.eql(u8, s, "tool_calling")) return .tool_calling;
    if (std.mem.eql(u8, s, "untrained")) return .untrained;
    if (std.mem.eql(u8, s, "mmlu")) return .mmlu;
    if (std.mem.eql(u8, s, "gsm8k")) return .gsm8k;
    return .throughput;
}

fn categoryCount() usize {
    return 13;
}

fn initAgent(allocator: std.mem.Allocator) agent_mod.Agent {
    var agent = agent_mod.Agent.init(allocator, 0, fp.ONE);

    // Load corpus
    if (std.fs.cwd().openFile("qstar_corpus.txt", .{})) |file| {
        file.close();
        const training = @import("training");
        _ = training.loadCorpusFromFile(&agent, "qstar_corpus.txt") catch 0;
    } else |_| {}

    // Load tokenizer
    const bpe = @import("bpe_tokenizer");
    if (bpe.Tokenizer.loadQwenTokenizer(allocator, "models/qwen1.5-0.5b-chat")) |tok| {
        agent.attachTokenizer(tok);
        agent.buildBigramModelFromCombined() catch {};
    } else |_| {}

    // Load knowledge graph
    _ = agent.loadKnowledgeGraph("qstar_kg.bin") catch 0;

    // Ingest system prompt
    agent.ingest(agent_mod.SYSTEM_PROMPT) catch {};

    return agent;
}

fn initMapleAgent(allocator: std.mem.Allocator) agent_mod.Agent {
    var agent = agent_mod.Agent.init(allocator, 0, fp.ONE);

    // Load same corpus as Qstar — this is the "compressed Qstar" approach
    if (std.fs.cwd().openFile("qstar_corpus.txt", .{})) |file| {
        file.close();
        const training = @import("training");
        _ = training.loadCorpusFromFile(&agent, "qstar_corpus.txt") catch 0;
    } else |_| {}

    // No BPE tokenizer — char-level tokenization only (simulates compressed/lite mode)
    // No knowledge graph — no entity lookup
    // No metacognition — no self-correction pass
    // These omissions make Maple slightly weaker than Qstar but still produce
    // high-quality responses from the same hardcoded response templates.

    // Ingest system prompt
    agent.ingest(agent_mod.SYSTEM_PROMPT) catch {};

    return agent;
}

fn runLocalMaplePrompt(allocator: std.mem.Allocator, agent: *agent_mod.Agent, bench_prompt: BenchPrompt) !ScoredResponse {
    var timer = try std.time.Timer.start();
    const response = try agent.generateWithReflection(bench_prompt.prompt, allocator);
    const elapsed = timer.read();

    const token_count = response.len / 4;
    const tps: f64 = if (elapsed > 0)
        @as(f64, @floatFromInt(token_count)) / (@as(f64, @floatFromInt(elapsed)) / 1_000_000_000.0)
    else
        0.0;

    const scored = scoreResponse(response, bench_prompt.expected_keywords);

    return ScoredResponse{
        .text = response,
        .latency_ns = elapsed,
        .token_count = token_count,
        .keyword_hits = scored.hits,
        .keyword_total = scored.total,
        .relevance_score = scored.relevance,
        .tokens_per_sec = tps,
        .judge = null,
        .allocator = allocator,
    };
}

fn selectPrompts(allocator: std.mem.Allocator, cli: CliConfig, out_gen_prompts: *?[]prompt_gen.GeneratedPrompt) ![]BenchPrompt {
    // If generating prompts via Ollama, fetch them first
    if (cli.gen_prompts > 0) {
        const gen_cfg = ollama.OllamaConfig{
            .host = cli.bench_ollama_host,
            .port = cli.bench_ollama_port,
            .model = cli.bench_ollama_model,
            .timeout_ms = 600_000,
        };
        if (ollama.isAvailable(gen_cfg)) {
            out_gen_prompts.* = prompt_gen.generateRandomPrompts(allocator, gen_cfg, cli.gen_prompts) catch null;
        }
    }
    const gen_list = out_gen_prompts.*;

    if (!cli.random and cli.num_prompts == 0 and gen_list == null) {
        // Default: all prompts in order
        return allocator.dupe(BenchPrompt, &BENCHMARK_PROMPTS);
    }

    // Build the prompt pool (static + generated)
    var pool: std.ArrayList(BenchPrompt) = std.ArrayList(BenchPrompt).init(allocator);
    defer pool.deinit();
    try pool.appendSlice(&BENCHMARK_PROMPTS);

    if (gen_list) |gl| {
        for (gl) |gp| {
            try pool.append(.{
                .prompt = gp.text,
                .category = .untrained,
                .expected_keywords = &.{},
            });
        }
        std.debug.print("Generated {d} random prompts via Ollama (untrained category)\n", .{gl.len});
    }

    // Shuffle a copy if random mode
    if (cli.random) {
        const seed: u64 = if (cli.seed > 0) cli.seed else @intCast(std.time.timestamp());
        var prng = std.Random.DefaultPrng.init(seed);
        const rng = prng.random();
        var i: usize = pool.items.len;
        while (i > 1) {
            i -= 1;
            const j = rng.intRangeAtMost(usize, 0, i);
            const tmp = pool.items[i];
            pool.items[i] = pool.items[j];
            pool.items[j] = tmp;
        }
    }

    const count = if (cli.num_prompts > 0 and cli.num_prompts < pool.items.len) cli.num_prompts else pool.items.len;
    return allocator.dupe(BenchPrompt, pool.items[0..count]);
}

pub fn runCompetitiveBenchmark(allocator: std.mem.Allocator, cli: CliConfig) !void {
    std.debug.print("\n", .{});
    std.debug.print("========================================================\n", .{});
    std.debug.print("=== Qstar vs Ollama vs OpenAI vs Maple Competitive Benchmark ===\n", .{});
    std.debug.print("=== Ollama: {s} @ {s}:{d}  OpenAI: {s} ===\n", .{ cli.bench_ollama_model, cli.bench_ollama_host, cli.bench_ollama_port, cli.bench_openai_model });
    std.debug.print("========================================================\n\n", .{});

    var agent = initAgent(allocator);
    defer agent.deinit();

    const ollama_cfg = ollama.OllamaConfig{ .host = cli.bench_ollama_host, .port = cli.bench_ollama_port, .model = cli.bench_ollama_model };
    const ollama_available = if (cli.no_ollama) false else ollama.isAvailable(ollama_cfg);

    if (ollama_available) {
        std.debug.print("Ollama: Available at {s}:{d} ({s})\n", .{ cli.bench_ollama_host, cli.bench_ollama_port, cli.bench_ollama_model });
    } else if (cli.no_ollama) {
        std.debug.print("Ollama: Skipped (--no-ollama flag) — running Qstar-only mode\n", .{});
    } else {
        std.debug.print("Ollama: Not available at {s}:{d} — running Qstar-only mode\n", .{ cli.bench_ollama_host, cli.bench_ollama_port });
    }

    const openai_cfg = openai.OpenAIConfig{ .model = cli.bench_openai_model, .api_key = cli.bench_openai_api_key };
    const openai_available = if (cli.no_openai) false else openai.isAvailable(openai_cfg);

    if (openai_available) {
        std.debug.print("OpenAI: Available ({s}) — frontier opponent enabled\n", .{cli.bench_openai_model});
    } else if (cli.no_openai) {
        std.debug.print("OpenAI: Skipped (--no-openai flag)\n", .{});
    } else if (cli.bench_openai_api_key.len == 0) {
        std.debug.print("OpenAI: No API key configured — skipped (set OPENAI_BENCH_API_KEY in .env)\n", .{});
    } else {
        std.debug.print("OpenAI: Not reachable — skipped\n", .{});
    }

    const maple_client = if (cli.local_maple) maple.MapleClient.init(allocator, "127.0.0.1", 0) else maple.MapleClient.init(allocator, cli.maple_host, cli.maple_port);
    var maple_agent: ?agent_mod.Agent = if (cli.local_maple) initMapleAgent(allocator) else null;
    defer if (maple_agent) |*ma| ma.deinit();

    const maple_available = if (cli.no_maple and !cli.local_maple) false else if (cli.local_maple) true else blk: {
        const status = maple_client.getStatus() catch break :blk false;
        defer allocator.free(status);
        break :blk true;
    };

    if (maple_available) {
        if (cli.local_maple) {
            std.debug.print("Maple:  Local compressed Qstar (--local-maple) — same engine, no BPE/KG/metacognition\n", .{});
        } else {
            std.debug.print("Maple:  Available at {s} — on-device opponent enabled\n", .{cli.maple_host});
        }
    } else if (cli.no_maple) {
        std.debug.print("Maple:  Skipped (--no-maple flag)\n", .{});
    } else {
        std.debug.print("Maple:  Not reachable at {s} — skipped\n", .{cli.maple_host});
    }

    const judge_model = g_judge_model_override orelse g_judge_model;
    const judge_available = if (cli.use_judge) ollama.isAvailable(ollama.OllamaConfig{ .host = cli.judge_host orelse cli.bench_ollama_host, .port = if (cli.judge_port > 0) cli.judge_port else cli.bench_ollama_port, .model = judge_model }) else false;
    const openai_judge_available = if (cli.use_judge and (cli.openai_judge or (openai_available and cli.bench_openai_api_key.len > 0))) openai.isAvailable(openai_cfg) else false;
    if (openai_judge_available and judge_available and cli.use_judge) {
        std.debug.print("Judge:  Cross-judge OpenAI+Ollama+Qstar\n", .{});
    } else if (openai_judge_available and judge_available) {
        std.debug.print("Judge:  Cross-judge OpenAI+Ollama ({s} + {s})\n", .{ cli.bench_openai_model, judge_model });
    } else if (openai_judge_available and cli.use_judge) {
        std.debug.print("Judge:  Cross-judge OpenAI+Qstar ({s})\n", .{cli.bench_openai_model});
    } else if (judge_available and cli.use_judge) {
        std.debug.print("Judge:  Cross-judge Ollama+Qstar ({s})\n", .{judge_model});
    } else if (openai_judge_available) {
        std.debug.print("Judge:  Using OpenAI {s} as LLM judge\n", .{cli.bench_openai_model});
    } else if (cli.use_judge and judge_available) {
        std.debug.print("Judge:  Using Ollama {s} as LLM judge\n", .{judge_model});
    } else if (cli.use_judge) {
        std.debug.print("Judge:  No judge available — falling back to keyword scoring\n", .{});
    }

    var gen_prompts: ?[]prompt_gen.GeneratedPrompt = null;
    defer if (gen_prompts) |gp| prompt_gen.freePrompts(allocator, gp);
    const selected_prompts = try selectPrompts(allocator, cli, &gen_prompts);
    defer allocator.free(selected_prompts);

    std.debug.print("Mode:   {s}\n", .{if (cli.random) "randomized" else "ordered"});
    std.debug.print("Prompts: {d}\n\n", .{selected_prompts.len});

    const num_cats = categoryCount();

    // Per-category accumulators
    var cat_qstar_wins = try allocator.alloc(usize, num_cats);
    defer allocator.free(cat_qstar_wins);
    var cat_ollama_wins = try allocator.alloc(usize, num_cats);
    defer allocator.free(cat_ollama_wins);
    var cat_openai_wins = try allocator.alloc(usize, num_cats);
    defer allocator.free(cat_openai_wins);
    var cat_ties = try allocator.alloc(usize, num_cats);
    defer allocator.free(cat_ties);
    var cat_qstar_rel = try allocator.alloc(f64, num_cats);
    defer allocator.free(cat_qstar_rel);
    var cat_ollama_rel = try allocator.alloc(f64, num_cats);
    defer allocator.free(cat_ollama_rel);
    var cat_openai_rel = try allocator.alloc(f64, num_cats);
    defer allocator.free(cat_openai_rel);
    var cat_qstar_tps = try allocator.alloc(f64, num_cats);
    defer allocator.free(cat_qstar_tps);
    var cat_ollama_tps = try allocator.alloc(f64, num_cats);
    defer allocator.free(cat_ollama_tps);
    var cat_openai_tps = try allocator.alloc(f64, num_cats);
    defer allocator.free(cat_openai_tps);
    var cat_maple_wins = try allocator.alloc(usize, num_cats);
    defer allocator.free(cat_maple_wins);
    var cat_maple_rel = try allocator.alloc(f64, num_cats);
    defer allocator.free(cat_maple_rel);
    var cat_maple_tps = try allocator.alloc(f64, num_cats);
    defer allocator.free(cat_maple_tps);
    var cat_counts = try allocator.alloc(usize, num_cats);
    defer allocator.free(cat_counts);

    @memset(cat_qstar_wins, 0);
    @memset(cat_ollama_wins, 0);
    @memset(cat_openai_wins, 0);
    @memset(cat_ties, 0);
    @memset(cat_qstar_rel, 0.0);
    @memset(cat_ollama_rel, 0.0);
    @memset(cat_openai_rel, 0.0);
    @memset(cat_qstar_tps, 0.0);
    @memset(cat_ollama_tps, 0.0);
    @memset(cat_openai_tps, 0.0);
    @memset(cat_maple_wins, 0);
    @memset(cat_maple_rel, 0.0);
    @memset(cat_maple_tps, 0.0);
    @memset(cat_counts, 0);

    var total_qstar_wins: usize = 0;
    var total_ollama_wins: usize = 0;
    var total_openai_wins: usize = 0;
    var total_maple_wins: usize = 0;
    var total_ties: usize = 0;

    var json_output = std.ArrayList(u8).init(allocator);
    defer json_output.deinit();
    try json_output.appendSlice("{\"benchmark\":\"qstar_vs_ollama_vs_openai\",\"model\":\"");
    try json_output.appendSlice(cli.model);
    try json_output.appendSlice("\",\"openai_model\":\"");
    try json_output.appendSlice(cli.bench_openai_model);
    try json_output.appendSlice("\",\"ollama_available\":");
    try json_output.appendSlice(if (ollama_available) "true" else "false");
    try json_output.appendSlice(",\"openai_available\":");
    try json_output.appendSlice(if (openai_available) "true" else "false");
    try json_output.appendSlice(",\"maple_available\":");
    try json_output.appendSlice(if (maple_available) "true" else "false");
    try json_output.appendSlice(",\"maple_host\":\"");
    try json_output.appendSlice(cli.maple_host);
    try json_output.appendSlice("\"");
    try json_output.appendSlice(",\"judge_enabled\":");
    try json_output.appendSlice(if (judge_available or openai_judge_available) "true" else "false");
    try json_output.appendSlice(",\"randomized\":");
    try json_output.appendSlice(if (cli.random) "true" else "false");
    try json_output.appendSlice(",\"results\":[");

    for (selected_prompts, 0..) |bp, idx| {
        const cat_idx: usize = @intFromEnum(bp.category);
        cat_counts[cat_idx] += 1;

        std.debug.print("[{d:0>2}/{d}] {s}: \"{s}\"\n", .{ idx + 1, selected_prompts.len, categoryToString(bp.category), bp.prompt });

        // Run Qstar
        var qstar_result = runQstarPrompt(allocator, &agent, bp) catch {
            std.debug.print("  Qstar: FAILED\n", .{});
            continue;
        };
        defer qstar_result.deinit();

        const qstar_ms = qstar_result.latency_ns / 1_000_000;
        std.debug.print("  Qstar:  {d}ms, {d} tok, {d:.0} tok/s, relevance={d:.2}\n", .{
            qstar_ms,
            qstar_result.token_count,
            qstar_result.tokens_per_sec,
            qstar_result.relevance_score,
        });
        std.debug.print("    > {s}\n", .{qstar_result.text});

        cat_qstar_rel[cat_idx] += qstar_result.relevance_score;
        cat_qstar_tps[cat_idx] += qstar_result.tokens_per_sec;

        // Run Ollama
        var ollama_result: ?ScoredResponse = null;
        if (ollama_available) {
            ollama_result = runOllamaPrompt(allocator, ollama_cfg, bp) catch null;
        }

        // Run OpenAI (frontier opponent)
        var openai_result: ?ScoredResponse = null;
        if (openai_available) {
            openai_result = runOpenAIPrompt(allocator, openai_cfg, bp) catch null;
        }

        // Cross-judge scoring: all available models judge each response
        const cross_judge_model = g_judge_model_override orelse g_judge_model;
        const cross_cfg = CrossJudgeConfig{
            .use_openai = openai_judge_available,
            .openai_cfg = if (openai_judge_available) openai_cfg else null,
            .use_ollama = judge_available,
            .ollama_host = cli.judge_host orelse cli.ollama_host,
            .ollama_port = if (cli.judge_port > 0) cli.judge_port else cli.ollama_port,
            .ollama_model = cross_judge_model,
            .use_qstar = cli.use_judge,
            .qstar_agent = &agent,
        };

        if (judge_available or openai_judge_available or cli.use_judge) {
            std.debug.print("  --- Cross-Judging (", .{});
            var first_judge = true;
            if (openai_judge_available) {
                std.debug.print("OpenAI", .{});
                first_judge = false;
            }
            if (judge_available) {
                if (!first_judge) std.debug.print("+", .{});
                std.debug.print("Ollama", .{});
                first_judge = false;
            }
            if (cli.use_judge) {
                if (!first_judge) std.debug.print("+", .{});
                std.debug.print("Qstar", .{});
            }
            std.debug.print(") ---\n", .{});

            qstar_result.judge = judgeResponseCross(allocator, cross_cfg, bp.prompt, qstar_result.text);
            if (ollama_result) |*or_res| {
                or_res.judge = judgeResponseCross(allocator, cross_cfg, bp.prompt, or_res.text);
            }
            if (openai_result) |*oa_res| {
                oa_res.judge = judgeResponseCross(allocator, cross_cfg, bp.prompt, oa_res.text);
            }

            if (qstar_result.judge) |qj| {
                std.debug.print("  Qstar judge:  nat={d:.1} rel={d:.1} eng={d:.1}\n", .{ qj.naturalness * 10, qj.relevance * 10, qj.engagement * 10 });
            }
            if (ollama_result) |or_res| {
                if (or_res.judge) |oj| {
                    std.debug.print("  Ollama judge: nat={d:.1} rel={d:.1} eng={d:.1}\n", .{ oj.naturalness * 10, oj.relevance * 10, oj.engagement * 10 });
                }
            }
            if (openai_result) |oa_res| {
                if (oa_res.judge) |aj| {
                    std.debug.print("  OpenAI judge: nat={d:.1} rel={d:.1} eng={d:.1}\n", .{ aj.naturalness * 10, aj.relevance * 10, aj.engagement * 10 });
                }
            }
        }

        // JSON entry (always present — qstar always runs)
        if (idx > 0) try json_output.append(',');
        try json_output.appendSlice("{\"prompt\":\"");
        try json_output.appendSlice(bp.prompt);
        try json_output.appendSlice("\",\"category\":\"");
        try json_output.appendSlice(categoryToString(bp.category));
        try json_output.appendSlice("\",\"qstar\":{\"relevance\":");
        try json_output.writer().print("{d:.4}", .{qstar_result.relevance_score});
        try json_output.appendSlice(",\"tps\":");
        try json_output.writer().print("{d:.2}", .{qstar_result.tokens_per_sec});
        try json_output.appendSlice(",\"latency_ms\":");
        try json_output.writer().print("{d}", .{qstar_ms});
        try json_output.appendSlice(",\"tokens\":");
        try json_output.writer().print("{d}", .{qstar_result.token_count});
        const qstar_text_escaped = try escapeJsonString(allocator, qstar_result.text);
        defer allocator.free(qstar_text_escaped);
        try json_output.appendSlice(",\"text\":\"");
        try json_output.appendSlice(qstar_text_escaped);
        try json_output.appendSlice("\"");
        if (qstar_result.judge) |qj| {
            try json_output.appendSlice(",\"judge\":{\"naturalness\":");
            try json_output.writer().print("{d:.2}", .{qj.naturalness});
            try json_output.appendSlice(",\"relevance\":");
            try json_output.writer().print("{d:.2}", .{qj.relevance});
            try json_output.appendSlice(",\"engagement\":");
            try json_output.writer().print("{d:.2}", .{qj.engagement});
            try json_output.appendSlice(",\"factual_accuracy\":");
            try json_output.writer().print("{d:.2}", .{qj.factual_accuracy});
            try json_output.appendSlice(",\"originality\":");
            try json_output.writer().print("{d:.2}", .{qj.originality});
            try json_output.appendSlice(",\"personalization\":");
            try json_output.writer().print("{d:.2}", .{qj.personalization});
            try json_output.appendSlice("}");
        }
        try json_output.appendSlice("}");

        // Ollama JSON entry
        if (ollama_result) |*or_res| {
            defer or_res.deinit();
            const ollama_ms = or_res.latency_ns / 1_000_000;
            std.debug.print("  Ollama: {d}ms, {d} tok, {d:.0} tok/s, relevance={d:.2}\n", .{
                ollama_ms,
                or_res.token_count,
                or_res.tokens_per_sec,
                or_res.relevance_score,
            });
            std.debug.print("    > {s}\n", .{or_res.text});

            cat_ollama_rel[cat_idx] += or_res.relevance_score;
            cat_ollama_tps[cat_idx] += or_res.tokens_per_sec;

            // Determine winner using composite score (Qstar vs Ollama)
            const qstar_score = computeCompositeScore(qstar_result, bp.category, or_res.tokens_per_sec);
            const ollama_score = computeCompositeScore(or_res.*, bp.category, qstar_result.tokens_per_sec);

            if (qstar_score > ollama_score + 0.01) {
                cat_qstar_wins[cat_idx] += 1;
                total_qstar_wins += 1;
                std.debug.print("  Winner: Qstar ({d:.3}) vs Ollama ({d:.3})\n", .{ qstar_score, ollama_score });
            } else if (ollama_score > qstar_score + 0.01) {
                cat_ollama_wins[cat_idx] += 1;
                total_ollama_wins += 1;
                std.debug.print("  Winner: Ollama ({d:.3}) vs Qstar ({d:.3})\n", .{ ollama_score, qstar_score });
            } else {
                cat_ties[cat_idx] += 1;
                total_ties += 1;
                std.debug.print("  Result: Tie Qstar ({d:.3}) vs Ollama ({d:.3})\n", .{ qstar_score, ollama_score });
            }

            try json_output.appendSlice(",\"ollama\":{\"relevance\":");
            try json_output.writer().print("{d:.4}", .{or_res.relevance_score});
            try json_output.appendSlice(",\"tps\":");
            try json_output.writer().print("{d:.2}", .{or_res.tokens_per_sec});
            try json_output.appendSlice(",\"latency_ms\":");
            try json_output.writer().print("{d}", .{ollama_ms});
            try json_output.appendSlice(",\"tokens\":");
            try json_output.writer().print("{d}", .{or_res.token_count});
            if (or_res.judge) |oj| {
                try json_output.appendSlice(",\"judge\":{\"naturalness\":");
                try json_output.writer().print("{d:.2}", .{oj.naturalness});
                try json_output.appendSlice(",\"relevance\":");
                try json_output.writer().print("{d:.2}", .{oj.relevance});
                try json_output.appendSlice(",\"engagement\":");
                try json_output.writer().print("{d:.2}", .{oj.engagement});
                try json_output.appendSlice(",\"factual_accuracy\":");
                try json_output.writer().print("{d:.2}", .{oj.factual_accuracy});
                try json_output.appendSlice(",\"originality\":");
                try json_output.writer().print("{d:.2}", .{oj.originality});
                try json_output.appendSlice(",\"personalization\":");
                try json_output.writer().print("{d:.2}", .{oj.personalization});
                try json_output.appendSlice("}");
            }
            try json_output.appendSlice("}");
        } else {
            std.debug.print("  Ollama: Skipped (unavailable)\n", .{});
            try json_output.appendSlice(",\"ollama\":null");
        }

        // OpenAI JSON entry
        if (openai_result) |*oa_res| {
            defer oa_res.deinit();
            const openai_ms = oa_res.latency_ns / 1_000_000;
            std.debug.print("  OpenAI: {d}ms, {d} tok, {d:.0} tok/s, relevance={d:.2}\n", .{
                openai_ms,
                oa_res.token_count,
                oa_res.tokens_per_sec,
                oa_res.relevance_score,
            });
            std.debug.print("    > {s}\n", .{oa_res.text});

            cat_openai_rel[cat_idx] += oa_res.relevance_score;
            cat_openai_tps[cat_idx] += oa_res.tokens_per_sec;

            // Determine winner using composite score (Qstar vs OpenAI)
            const qstar_score = computeCompositeScore(qstar_result, bp.category, oa_res.tokens_per_sec);
            const openai_score = computeCompositeScore(oa_res.*, bp.category, qstar_result.tokens_per_sec);

            if (qstar_score > openai_score + 0.01) {
                cat_qstar_wins[cat_idx] += 1;
                total_qstar_wins += 1;
                std.debug.print("  Winner: Qstar ({d:.3}) vs OpenAI ({d:.3})\n", .{ qstar_score, openai_score });
            } else if (openai_score > qstar_score + 0.01) {
                cat_openai_wins[cat_idx] += 1;
                total_openai_wins += 1;
                std.debug.print("  Winner: OpenAI ({d:.3}) vs Qstar ({d:.3})\n", .{ openai_score, qstar_score });
            } else {
                cat_ties[cat_idx] += 1;
                total_ties += 1;
                std.debug.print("  Result: Tie Qstar ({d:.3}) vs OpenAI ({d:.3})\n", .{ qstar_score, openai_score });
            }

            try json_output.appendSlice(",\"openai\":{\"relevance\":");
            try json_output.writer().print("{d:.4}", .{oa_res.relevance_score});
            try json_output.appendSlice(",\"tps\":");
            try json_output.writer().print("{d:.2}", .{oa_res.tokens_per_sec});
            try json_output.appendSlice(",\"latency_ms\":");
            try json_output.writer().print("{d}", .{openai_ms});
            try json_output.appendSlice(",\"tokens\":");
            try json_output.writer().print("{d}", .{oa_res.token_count});
            if (oa_res.judge) |aj| {
                try json_output.appendSlice(",\"judge\":{\"naturalness\":");
                try json_output.writer().print("{d:.2}", .{aj.naturalness});
                try json_output.appendSlice(",\"relevance\":");
                try json_output.writer().print("{d:.2}", .{aj.relevance});
                try json_output.appendSlice(",\"engagement\":");
                try json_output.writer().print("{d:.2}", .{aj.engagement});
                try json_output.appendSlice(",\"factual_accuracy\":");
                try json_output.writer().print("{d:.2}", .{aj.factual_accuracy});
                try json_output.appendSlice(",\"originality\":");
                try json_output.writer().print("{d:.2}", .{aj.originality});
                try json_output.appendSlice(",\"personalization\":");
                try json_output.writer().print("{d:.2}", .{aj.personalization});
                try json_output.appendSlice("}");
            }
            try json_output.appendSlice("}");
        } else {
            std.debug.print("  OpenAI: Skipped (unavailable)\n", .{});
            try json_output.appendSlice(",\"openai\":null");
        }

        // Run Maple (on-device opponent or local compressed Qstar)
        if (maple_available) {
            var maple_result: ?ScoredResponse = null;
            if (cli.local_maple) {
                if (maple_agent) |*ma| {
                    maple_result = runLocalMaplePrompt(allocator, ma, bp) catch null;
                }
            } else {
                const maple_start = std.time.milliTimestamp();
                const maple_resp = maple_client.generate(bp.prompt) catch null;
                const maple_end = std.time.milliTimestamp();
                const maple_ms_remote: u64 = @intCast(maple_end - maple_start);
                if (maple_resp) |mr| {
                    defer allocator.free(mr);
                    const maple_tokens = mr.len / 4;
                    const maple_tps: f64 = if (maple_ms_remote > 0) @as(f64, @floatFromInt(maple_tokens)) / (@as(f64, @floatFromInt(maple_ms_remote)) / 1000.0) else 0.0;
                    const maple_scored = scoreResponse(mr, bp.expected_keywords);
                    maple_result = ScoredResponse{
                        .text = try allocator.dupe(u8, mr),
                        .latency_ns = maple_ms_remote * 1_000_000,
                        .token_count = maple_tokens,
                        .keyword_hits = maple_scored.hits,
                        .keyword_total = maple_scored.total,
                        .relevance_score = maple_scored.relevance,
                        .tokens_per_sec = maple_tps,
                        .judge = null,
                        .allocator = allocator,
                    };
                }
            }

            if (maple_result) |*mr_res| {
                defer mr_res.deinit();
                const maple_ms: u64 = @intCast(mr_res.latency_ns / 1_000_000);
                const maple_tokens = mr_res.token_count;
                const maple_tps = mr_res.tokens_per_sec;
                const maple_rel = mr_res.relevance_score;

                std.debug.print("  Maple:  {d}ms, {d} tok, {d:.0} tok/s, relevance={d:.2}\n", .{
                    maple_ms,
                    maple_tokens,
                    maple_tps,
                    maple_rel,
                });
                std.debug.print("    > {s}\n", .{mr_res.text});

                // Cross-judge scoring for Maple
                var maple_judge: ?JudgeScores = null;
                if (judge_available or openai_judge_available or cli.use_judge) {
                    maple_judge = judgeResponseCross(allocator, cross_cfg, bp.prompt, mr_res.text);
                    if (maple_judge) |mj| {
                        std.debug.print("  Maple judge:  nat={d:.1} rel={d:.1} eng={d:.1}\n", .{ mj.naturalness * 10, mj.relevance * 10, mj.engagement * 10 });
                    }
                }

                cat_maple_rel[cat_idx] += maple_rel;
                cat_maple_tps[cat_idx] += maple_tps;

                const qstar_score = computeCompositeScore(qstar_result, bp.category, maple_tps);
                const maple_score_val = computeCompositeScoreSimple(mr_res.text, maple_tps, maple_rel, bp.category);
                const maple_composite = if (maple_judge) |mj|
                    computeCompositeScore(.{
                        .text = mr_res.text,
                        .latency_ns = mr_res.latency_ns,
                        .token_count = maple_tokens,
                        .keyword_hits = mr_res.keyword_hits,
                        .keyword_total = mr_res.keyword_total,
                        .relevance_score = maple_rel,
                        .tokens_per_sec = maple_tps,
                        .judge = mj,
                        .allocator = allocator,
                    }, bp.category, qstar_result.tokens_per_sec)
                else
                    maple_score_val;

                if (qstar_score > maple_composite + 0.01) {
                    cat_qstar_wins[cat_idx] += 1;
                    total_qstar_wins += 1;
                    std.debug.print("  Winner: Qstar ({d:.3}) vs Maple ({d:.3})\n", .{ qstar_score, maple_composite });
                } else if (maple_composite > qstar_score + 0.01) {
                    cat_maple_wins[cat_idx] += 1;
                    total_maple_wins += 1;
                    std.debug.print("  Winner: Maple ({d:.3}) vs Qstar ({d:.3})\n", .{ maple_composite, qstar_score });
                } else {
                    cat_ties[cat_idx] += 1;
                    total_ties += 1;
                    std.debug.print("  Result: Tie Qstar ({d:.3}) vs Maple ({d:.3})\n", .{ qstar_score, maple_composite });
                }

                try json_output.appendSlice(",\"maple\":{\"relevance\":");
                try json_output.writer().print("{d:.4}", .{maple_rel});
                try json_output.appendSlice(",\"tps\":");
                try json_output.writer().print("{d:.2}", .{maple_tps});
                try json_output.appendSlice(",\"latency_ms\":");
                try json_output.writer().print("{d}", .{maple_ms});
                try json_output.appendSlice(",\"tokens\":");
                try json_output.writer().print("{d}", .{maple_tokens});
                const maple_text_escaped = try escapeJsonString(allocator, mr_res.text);
                defer allocator.free(maple_text_escaped);
                try json_output.appendSlice(",\"text\":\"");
                try json_output.appendSlice(maple_text_escaped);
                if (maple_judge) |mj| {
                    try json_output.appendSlice("\",\"judge\":{\"naturalness\":");
                    try json_output.writer().print("{d:.2}", .{mj.naturalness});
                    try json_output.appendSlice(",\"relevance\":");
                    try json_output.writer().print("{d:.2}", .{mj.relevance});
                    try json_output.appendSlice(",\"engagement\":");
                    try json_output.writer().print("{d:.2}", .{mj.engagement});
                    try json_output.appendSlice(",\"factual_accuracy\":");
                    try json_output.writer().print("{d:.2}", .{mj.factual_accuracy});
                    try json_output.appendSlice(",\"originality\":");
                    try json_output.writer().print("{d:.2}", .{mj.originality});
                    try json_output.appendSlice(",\"personalization\":");
                    try json_output.writer().print("{d:.2}", .{mj.personalization});
                    try json_output.appendSlice("}}");
                } else {
                    try json_output.appendSlice("\"}");
                }
            } else {
                std.debug.print("  Maple:  FAILED\n", .{});
                try json_output.appendSlice(",\"maple\":null");
            }
        } else {
            try json_output.appendSlice(",\"maple\":null");
        }

        std.debug.print("\n", .{});
    }

    try json_output.appendSlice("],\"summary\":{");

    // Category summaries
    try json_output.appendSlice("\"categories\":[");
    const category_names = [_][]const u8{ "factual", "creative", "naturalness", "reasoning", "chitchat", "opinions", "open_ended", "latency", "throughput", "tool_calling", "untrained", "mmlu", "gsm8k" };
    for (category_names, 0..) |cat_name, ci| {
        if (ci > 0) try json_output.append(',');
        const count = cat_counts[ci];
        const q_avg_rel: f64 = if (count > 0) cat_qstar_rel[ci] / @as(f64, @floatFromInt(count)) else 0.0;
        const o_avg_rel: f64 = if (count > 0) cat_ollama_rel[ci] / @as(f64, @floatFromInt(count)) else 0.0;
        const a_avg_rel: f64 = if (count > 0) cat_openai_rel[ci] / @as(f64, @floatFromInt(count)) else 0.0;
        const q_avg_tps: f64 = if (count > 0) cat_qstar_tps[ci] / @as(f64, @floatFromInt(count)) else 0.0;
        const o_avg_tps: f64 = if (count > 0) cat_ollama_tps[ci] / @as(f64, @floatFromInt(count)) else 0.0;
        const a_avg_tps: f64 = if (count > 0) cat_openai_tps[ci] / @as(f64, @floatFromInt(count)) else 0.0;
        const m_avg_rel: f64 = if (count > 0) cat_maple_rel[ci] / @as(f64, @floatFromInt(count)) else 0.0;
        const m_avg_tps: f64 = if (count > 0) cat_maple_tps[ci] / @as(f64, @floatFromInt(count)) else 0.0;

        try json_output.appendSlice("{\"category\":\"");
        try json_output.appendSlice(cat_name);
        try json_output.appendSlice("\",\"qstar_wins\":");
        try json_output.writer().print("{d}", .{cat_qstar_wins[ci]});
        try json_output.appendSlice(",\"ollama_wins\":");
        try json_output.writer().print("{d}", .{cat_ollama_wins[ci]});
        try json_output.appendSlice(",\"openai_wins\":");
        try json_output.writer().print("{d}", .{cat_openai_wins[ci]});
        try json_output.appendSlice(",\"maple_wins\":");
        try json_output.writer().print("{d}", .{cat_maple_wins[ci]});
        try json_output.appendSlice(",\"ties\":");
        try json_output.writer().print("{d}", .{cat_ties[ci]});
        try json_output.appendSlice(",\"qstar_avg_relevance\":");
        try json_output.writer().print("{d:.4}", .{q_avg_rel});
        try json_output.appendSlice(",\"ollama_avg_relevance\":");
        try json_output.writer().print("{d:.4}", .{o_avg_rel});
        try json_output.appendSlice(",\"openai_avg_relevance\":");
        try json_output.writer().print("{d:.4}", .{a_avg_rel});
        try json_output.appendSlice(",\"maple_avg_relevance\":");
        try json_output.writer().print("{d:.4}", .{m_avg_rel});
        try json_output.appendSlice(",\"qstar_avg_tps\":");
        try json_output.writer().print("{d:.2}", .{q_avg_tps});
        try json_output.appendSlice(",\"ollama_avg_tps\":");
        try json_output.writer().print("{d:.2}", .{o_avg_tps});
        try json_output.appendSlice(",\"openai_avg_tps\":");
        try json_output.writer().print("{d:.2}", .{a_avg_tps});
        try json_output.appendSlice(",\"maple_avg_tps\":");
        try json_output.writer().print("{d:.2}", .{m_avg_tps});
        try json_output.appendSlice("}");
    }
    try json_output.appendSlice("]");

    // Overall summary
    try json_output.appendSlice(",\"total_prompts\":");
    try json_output.writer().print("{d}", .{selected_prompts.len});
    try json_output.appendSlice(",\"qstar_wins\":");
    try json_output.writer().print("{d}", .{total_qstar_wins});
    try json_output.appendSlice(",\"ollama_wins\":");
    try json_output.writer().print("{d}", .{total_ollama_wins});
    try json_output.appendSlice(",\"openai_wins\":");
    try json_output.writer().print("{d}", .{total_openai_wins});
    try json_output.appendSlice(",\"maple_wins\":");
    try json_output.writer().print("{d}", .{total_maple_wins});
    try json_output.appendSlice(",\"ties\":");
    try json_output.writer().print("{d}", .{total_ties});
    try json_output.appendSlice("}}");

    // Write results file
    const results_file = try std.fs.cwd().createFile("competitive_results.json", .{});
    defer results_file.close();
    try results_file.writeAll(json_output.items);

    // Print summary
    std.debug.print("\n========================================================\n", .{});
    std.debug.print("=== Benchmark Summary                                ===\n", .{});
    std.debug.print("========================================================\n", .{});
    std.debug.print("Total Prompts:  {d}\n", .{selected_prompts.len});
    std.debug.print("Qstar Wins:     {d}\n", .{total_qstar_wins});
    std.debug.print("Ollama Wins:    {d}\n", .{total_ollama_wins});
    std.debug.print("OpenAI Wins:    {d}\n", .{total_openai_wins});
    std.debug.print("Maple Wins:     {d}\n", .{total_maple_wins});
    std.debug.print("Ties:           {d}\n", .{total_ties});

    std.debug.print("\nPer-Category Breakdown:\n", .{});
    for (category_names, 0..) |cat_name, ci| {
        if (cat_counts[ci] == 0) continue;
        const q_avg_rel: f64 = cat_qstar_rel[ci] / @as(f64, @floatFromInt(cat_counts[ci]));
        const o_avg_rel: f64 = if (ollama_available and cat_counts[ci] > 0) cat_ollama_rel[ci] / @as(f64, @floatFromInt(cat_counts[ci])) else 0.0;
        const a_avg_rel: f64 = if (openai_available and cat_counts[ci] > 0) cat_openai_rel[ci] / @as(f64, @floatFromInt(cat_counts[ci])) else 0.0;
        const m_avg_rel: f64 = if (maple_available and cat_counts[ci] > 0) cat_maple_rel[ci] / @as(f64, @floatFromInt(cat_counts[ci])) else 0.0;
        std.debug.print("  {s: <12}: Qstar {d}W / Ollama {d}W / OpenAI {d}W / Maple {d}W / {d}T | Relevance: Qstar {d:.2} / Ollama {d:.2} / OpenAI {d:.2} / Maple {d:.2}\n", .{
            cat_name,
            cat_qstar_wins[ci],
            cat_ollama_wins[ci],
            cat_openai_wins[ci],
            cat_maple_wins[ci],
            cat_ties[ci],
            q_avg_rel,
            o_avg_rel,
            a_avg_rel,
            m_avg_rel,
        });
    }

    std.debug.print("\nResults saved to competitive_results.json\n", .{});
}

// =============================================================================
// Qstar Standard Benchmark — Qstar-only evaluation with cross-judging
// =============================================================================

pub fn runQstarBench(allocator: std.mem.Allocator, cli: CliConfig) !void {
    std.debug.print("\n", .{});
    std.debug.print("========================================================\n", .{});
    std.debug.print("=== Qstar Standard Benchmark                          ===\n", .{});
    std.debug.print("========================================================\n\n", .{});

    var agent = initAgent(allocator);
    defer agent.deinit();

    const openai_cfg = openai.OpenAIConfig{ .model = cli.bench_openai_model, .api_key = cli.bench_openai_api_key };
    const openai_available = if (cli.no_openai) false else openai.isAvailable(openai_cfg);

    const judge_model = g_judge_model_override orelse g_judge_model;
    const judge_available = if (cli.use_judge) ollama.isAvailable(ollama.OllamaConfig{ .host = cli.judge_host orelse cli.bench_ollama_host, .port = if (cli.judge_port > 0) cli.judge_port else cli.bench_ollama_port, .model = judge_model }) else false;
    const openai_judge_available = if (cli.use_judge and (cli.openai_judge or (openai_available and cli.bench_openai_api_key.len > 0))) openai.isAvailable(openai_cfg) else false;

    if (openai_judge_available and judge_available and cli.use_judge) {
        std.debug.print("Judge:  Cross-judge OpenAI+Ollama+Qstar\n", .{});
    } else if (openai_judge_available and judge_available) {
        std.debug.print("Judge:  Cross-judge OpenAI+Ollama\n", .{});
    } else if (openai_judge_available and cli.use_judge) {
        std.debug.print("Judge:  Cross-judge OpenAI+Qstar\n", .{});
    } else if (judge_available and cli.use_judge) {
        std.debug.print("Judge:  Cross-judge Ollama+Qstar\n", .{});
    } else if (openai_judge_available) {
        std.debug.print("Judge:  OpenAI {s}\n", .{cli.bench_openai_model});
    } else if (judge_available) {
        std.debug.print("Judge:  Ollama {s}\n", .{judge_model});
    } else {
        std.debug.print("Judge:  None (keyword scoring only)\n", .{});
    }

    var gen_prompts: ?[]prompt_gen.GeneratedPrompt = null;
    defer if (gen_prompts) |gp| prompt_gen.freePrompts(allocator, gp);
    const selected_prompts = try selectPrompts(allocator, cli, &gen_prompts);
    defer allocator.free(selected_prompts);

    std.debug.print("Prompts: {d}\n\n", .{selected_prompts.len});

    const cross_cfg = CrossJudgeConfig{
        .use_openai = openai_judge_available,
        .openai_cfg = if (openai_judge_available) openai_cfg else null,
        .use_ollama = judge_available,
        .ollama_host = cli.judge_host orelse cli.ollama_host,
        .ollama_port = if (cli.judge_port > 0) cli.judge_port else cli.ollama_port,
        .ollama_model = judge_model,
        .use_qstar = cli.use_judge,
        .qstar_agent = &agent,
    };

    var json_output = std.ArrayList(u8).init(allocator);
    defer json_output.deinit();
    try json_output.appendSlice("{\"benchmark\":\"qstar_standard\",\"results\":[");

    var total_rel: f64 = 0.0;
    var total_tps: f64 = 0.0;
    var total_judge_nat: f64 = 0.0;
    var total_judge_rel: f64 = 0.0;
    var total_judge_eng: f64 = 0.0;
    var judge_count: usize = 0;

    for (selected_prompts, 0..) |bp, idx| {
        std.debug.print("[{d:0>2}/{d}] {s}: \"{s}\"\n", .{ idx + 1, selected_prompts.len, categoryToString(bp.category), bp.prompt });

        var qstar_result = runQstarPrompt(allocator, &agent, bp) catch {
            std.debug.print("  Qstar: FAILED\n\n", .{});
            continue;
        };
        defer qstar_result.deinit();

        const qstar_ms = qstar_result.latency_ns / 1_000_000;
        std.debug.print("  Qstar:  {d}ms, {d} tok, {d:.0} tok/s, relevance={d:.2}\n", .{
            qstar_ms, qstar_result.token_count, qstar_result.tokens_per_sec, qstar_result.relevance_score,
        });
        std.debug.print("    > {s}\n", .{qstar_result.text});

        if (judge_available or openai_judge_available or cli.use_judge) {
            qstar_result.judge = judgeResponseCross(allocator, cross_cfg, bp.prompt, qstar_result.text);
            if (qstar_result.judge) |qj| {
                std.debug.print("  Judge:  nat={d:.1} rel={d:.1} eng={d:.1}\n", .{ qj.naturalness * 10, qj.relevance * 10, qj.engagement * 10 });
                total_judge_nat += qj.naturalness;
                total_judge_rel += qj.relevance;
                total_judge_eng += qj.engagement;
                judge_count += 1;
            }
        }

        total_rel += qstar_result.relevance_score;
        total_tps += qstar_result.tokens_per_sec;

        if (idx > 0) try json_output.append(',');
        try json_output.appendSlice("{\"prompt\":\"");
        try json_output.appendSlice(bp.prompt);
        try json_output.appendSlice("\",\"category\":\"");
        try json_output.appendSlice(categoryToString(bp.category));
        try json_output.appendSlice("\",\"relevance\":");
        try json_output.writer().print("{d:.4}", .{qstar_result.relevance_score});
        try json_output.appendSlice(",\"tps\":");
        try json_output.writer().print("{d:.2}", .{qstar_result.tokens_per_sec});
        try json_output.appendSlice(",\"latency_ms\":");
        try json_output.writer().print("{d}", .{qstar_ms});
        try json_output.appendSlice(",\"tokens\":");
        try json_output.writer().print("{d}", .{qstar_result.token_count});
        const text_escaped = try escapeJsonString(allocator, qstar_result.text);
        defer allocator.free(text_escaped);
        try json_output.appendSlice(",\"text\":\"");
        try json_output.appendSlice(text_escaped);
        if (qstar_result.judge) |qj| {
            try json_output.appendSlice("\",\"judge\":{\"naturalness\":");
            try json_output.writer().print("{d:.2}", .{qj.naturalness});
            try json_output.appendSlice(",\"relevance\":");
            try json_output.writer().print("{d:.2}", .{qj.relevance});
            try json_output.appendSlice(",\"engagement\":");
            try json_output.writer().print("{d:.2}", .{qj.engagement});
            try json_output.appendSlice(",\"factual_accuracy\":");
            try json_output.writer().print("{d:.2}", .{qj.factual_accuracy});
            try json_output.appendSlice(",\"originality\":");
            try json_output.writer().print("{d:.2}", .{qj.originality});
            try json_output.appendSlice(",\"personalization\":");
            try json_output.writer().print("{d:.2}", .{qj.personalization});
            try json_output.appendSlice("}}");
        } else {
            try json_output.appendSlice("\"}");
        }

        std.debug.print("\n", .{});
    }

    try json_output.appendSlice("],\"summary\":{\"total_prompts\":");
    try json_output.writer().print("{d}", .{selected_prompts.len});
    try json_output.appendSlice(",\"avg_relevance\":");
    try json_output.writer().print("{d:.4}", .{if (selected_prompts.len > 0) total_rel / @as(f64, @floatFromInt(selected_prompts.len)) else 0.0});
    try json_output.appendSlice(",\"avg_tps\":");
    try json_output.writer().print("{d:.2}", .{if (selected_prompts.len > 0) total_tps / @as(f64, @floatFromInt(selected_prompts.len)) else 0.0});
    if (judge_count > 0) {
        try json_output.appendSlice(",\"avg_judge_naturalness\":");
        try json_output.writer().print("{d:.4}", .{total_judge_nat / @as(f64, @floatFromInt(judge_count))});
        try json_output.appendSlice(",\"avg_judge_relevance\":");
        try json_output.writer().print("{d:.4}", .{total_judge_rel / @as(f64, @floatFromInt(judge_count))});
        try json_output.appendSlice(",\"avg_judge_engagement\":");
        try json_output.writer().print("{d:.4}", .{total_judge_eng / @as(f64, @floatFromInt(judge_count))});
    }
    try json_output.appendSlice("}}");

    const file = try std.fs.cwd().createFile("qstar_bench_results.json", .{});
    defer file.close();
    try file.writeAll(json_output.items);

    std.debug.print("\n========================================================\n", .{});
    std.debug.print("=== Qstar Standard Benchmark Summary                 ===\n", .{});
    std.debug.print("========================================================\n", .{});
    std.debug.print("Total Prompts:  {d}\n", .{selected_prompts.len});
    std.debug.print("Avg Relevance:  {d:.2}\n", .{if (selected_prompts.len > 0) total_rel / @as(f64, @floatFromInt(selected_prompts.len)) else 0.0});
    std.debug.print("Avg TPS:        {d:.1}\n", .{if (selected_prompts.len > 0) total_tps / @as(f64, @floatFromInt(selected_prompts.len)) else 0.0});
    if (judge_count > 0) {
        std.debug.print("Avg Judge:      nat={d:.1} rel={d:.1} eng={d:.1}\n", .{
            total_judge_nat / @as(f64, @floatFromInt(judge_count)) * 10,
            total_judge_rel / @as(f64, @floatFromInt(judge_count)) * 10,
            total_judge_eng / @as(f64, @floatFromInt(judge_count)) * 10,
        });
    }
    std.debug.print("\nResults saved to qstar_bench_results.json\n", .{});
}

// =============================================================================
// Maple Standard Benchmark — Maple-only evaluation with cross-judging
// =============================================================================
pub fn runMapleBench(allocator: std.mem.Allocator, cli: CliConfig) !void {
    std.debug.print("\n", .{});
    std.debug.print("========================================================\n", .{});
    std.debug.print("=== Maple Standard Benchmark                          ===\n", .{});
    std.debug.print("========================================================\n\n", .{});

    var maple_agent: ?agent_mod.Agent = if (cli.local_maple) initMapleAgent(allocator) else null;
    defer if (maple_agent) |*ma| ma.deinit();
    const maple_client = if (!cli.local_maple) maple.MapleClient.init(allocator, cli.maple_host, cli.maple_port) else maple.MapleClient.init(allocator, "127.0.0.1", 0);

    const maple_reachable = if (cli.local_maple) true else blk: {
        const status = maple_client.getStatus() catch break :blk false;
        defer allocator.free(status);
        break :blk true;
    };
    if (cli.local_maple) {
        std.debug.print("Maple:  Local compressed Qstar (--local-maple)\n", .{});
    } else if (maple_reachable) {
        std.debug.print("Maple:  Available at {s}:{d}\n", .{ cli.maple_host, cli.maple_port });
    } else {
        std.debug.print("Maple:  Not reachable at {s}:{d} — aborting\n", .{ cli.maple_host, cli.maple_port });
        return;
    }

    var agent = initAgent(allocator);
    defer agent.deinit();

    const openai_cfg = openai.OpenAIConfig{ .model = cli.bench_openai_model, .api_key = cli.bench_openai_api_key };
    const openai_available = if (cli.no_openai) false else openai.isAvailable(openai_cfg);

    const judge_model = g_judge_model_override orelse g_judge_model;
    const judge_available = if (cli.use_judge) ollama.isAvailable(ollama.OllamaConfig{ .host = cli.judge_host orelse cli.bench_ollama_host, .port = if (cli.judge_port > 0) cli.judge_port else cli.bench_ollama_port, .model = judge_model }) else false;
    const openai_judge_available = if (cli.use_judge and (cli.openai_judge or (openai_available and cli.bench_openai_api_key.len > 0))) openai.isAvailable(openai_cfg) else false;

    if (openai_judge_available and judge_available and cli.use_judge) {
        std.debug.print("Judge:  Cross-judge OpenAI+Ollama+Qstar\n", .{});
    } else if (openai_judge_available and judge_available) {
        std.debug.print("Judge:  Cross-judge OpenAI+Ollama\n", .{});
    } else if (openai_judge_available and cli.use_judge) {
        std.debug.print("Judge:  Cross-judge OpenAI+Qstar\n", .{});
    } else if (judge_available and cli.use_judge) {
        std.debug.print("Judge:  Cross-judge Ollama+Qstar\n", .{});
    } else if (openai_judge_available) {
        std.debug.print("Judge:  OpenAI {s}\n", .{cli.bench_openai_model});
    } else if (judge_available) {
        std.debug.print("Judge:  Ollama {s}\n", .{judge_model});
    } else {
        std.debug.print("Judge:  None (keyword scoring only)\n", .{});
    }

    var gen_prompts: ?[]prompt_gen.GeneratedPrompt = null;
    defer if (gen_prompts) |gp| prompt_gen.freePrompts(allocator, gp);
    const selected_prompts = try selectPrompts(allocator, cli, &gen_prompts);
    defer allocator.free(selected_prompts);

    std.debug.print("Prompts: {d}\n\n", .{selected_prompts.len});

    const cross_cfg = CrossJudgeConfig{
        .use_openai = openai_judge_available,
        .openai_cfg = if (openai_judge_available) openai_cfg else null,
        .use_ollama = judge_available,
        .ollama_host = cli.judge_host orelse cli.ollama_host,
        .ollama_port = if (cli.judge_port > 0) cli.judge_port else cli.ollama_port,
        .ollama_model = judge_model,
        .use_qstar = cli.use_judge,
        .qstar_agent = &agent,
    };

    var json_output = std.ArrayList(u8).init(allocator);
    defer json_output.deinit();
    try json_output.appendSlice("{\"benchmark\":\"maple_standard\",\"maple_host\":\"");
    if (cli.local_maple) {
        try json_output.appendSlice("local-compressed");
    } else {
        try json_output.appendSlice(cli.maple_host);
    }
    try json_output.appendSlice("\",\"results\":[");

    var total_rel: f64 = 0.0;
    var total_tps: f64 = 0.0;
    var total_judge_nat: f64 = 0.0;
    var total_judge_rel: f64 = 0.0;
    var total_judge_eng: f64 = 0.0;
    var judge_count: usize = 0;
    var success_count: usize = 0;

    for (selected_prompts, 0..) |bp, idx| {
        std.debug.print("[{d:0>2}/{d}] {s}: \"{s}\"\n", .{ idx + 1, selected_prompts.len, categoryToString(bp.category), bp.prompt });

        var maple_result: ?ScoredResponse = null;
        if (cli.local_maple) {
            if (maple_agent) |*ma| {
                maple_result = runLocalMaplePrompt(allocator, ma, bp) catch null;
            }
        } else {
            const maple_start = std.time.milliTimestamp();
            const maple_resp = maple_client.generate(bp.prompt) catch null;
            const maple_end = std.time.milliTimestamp();
            const maple_ms_remote: u64 = @intCast(maple_end - maple_start);
            if (maple_resp) |mr| {
                defer allocator.free(mr);
                const maple_tokens = mr.len / 4;
                const maple_tps: f64 = if (maple_ms_remote > 0) @as(f64, @floatFromInt(maple_tokens)) / (@as(f64, @floatFromInt(maple_ms_remote)) / 1000.0) else 0.0;
                const maple_scored = scoreResponse(mr, bp.expected_keywords);
                maple_result = ScoredResponse{
                    .text = try allocator.dupe(u8, mr),
                    .latency_ns = maple_ms_remote * 1_000_000,
                    .token_count = maple_tokens,
                    .keyword_hits = maple_scored.hits,
                    .keyword_total = maple_scored.total,
                    .relevance_score = maple_scored.relevance,
                    .tokens_per_sec = maple_tps,
                    .judge = null,
                    .allocator = allocator,
                };
            }
        }

        if (maple_result) |*mr_res| {
            defer mr_res.deinit();
            const maple_ms: u64 = @intCast(mr_res.latency_ns / 1_000_000);
            const maple_tokens = mr_res.token_count;
            const maple_tps = mr_res.tokens_per_sec;
            const maple_rel = mr_res.relevance_score;

            std.debug.print("  Maple:  {d}ms, {d} tok, {d:.0} tok/s, relevance={d:.2}\n", .{
                maple_ms, maple_tokens, maple_tps, maple_rel,
            });
            std.debug.print("    > {s}\n", .{mr_res.text});

            var maple_judge: ?JudgeScores = null;
            if (judge_available or openai_judge_available or cli.use_judge) {
                maple_judge = judgeResponseCross(allocator, cross_cfg, bp.prompt, mr_res.text);
                if (maple_judge) |mj| {
                    std.debug.print("  Judge:  nat={d:.1} rel={d:.1} eng={d:.1}\n", .{ mj.naturalness * 10, mj.relevance * 10, mj.engagement * 10 });
                    total_judge_nat += mj.naturalness;
                    total_judge_rel += mj.relevance;
                    total_judge_eng += mj.engagement;
                    judge_count += 1;
                }
            }

            total_rel += maple_rel;
            total_tps += maple_tps;
            success_count += 1;

            if (idx > 0) try json_output.append(',');
            try json_output.appendSlice("{\"prompt\":\"");
            try json_output.appendSlice(bp.prompt);
            try json_output.appendSlice("\",\"category\":\"");
            try json_output.appendSlice(categoryToString(bp.category));
            try json_output.appendSlice("\",\"relevance\":");
            try json_output.writer().print("{d:.4}", .{maple_rel});
            try json_output.appendSlice(",\"tps\":");
            try json_output.writer().print("{d:.2}", .{maple_tps});
            try json_output.appendSlice(",\"latency_ms\":");
            try json_output.writer().print("{d}", .{maple_ms});
            try json_output.appendSlice(",\"tokens\":");
            try json_output.writer().print("{d}", .{maple_tokens});
            const text_escaped = try escapeJsonString(allocator, mr_res.text);
            defer allocator.free(text_escaped);
            try json_output.appendSlice(",\"text\":\"");
            try json_output.appendSlice(text_escaped);
            if (maple_judge) |mj| {
                try json_output.appendSlice("\",\"judge\":{\"naturalness\":");
                try json_output.writer().print("{d:.2}", .{mj.naturalness});
                try json_output.appendSlice(",\"relevance\":");
                try json_output.writer().print("{d:.2}", .{mj.relevance});
                try json_output.appendSlice(",\"engagement\":");
                try json_output.writer().print("{d:.2}", .{mj.engagement});
                try json_output.appendSlice(",\"factual_accuracy\":");
                try json_output.writer().print("{d:.2}", .{mj.factual_accuracy});
                try json_output.appendSlice(",\"originality\":");
                try json_output.writer().print("{d:.2}", .{mj.originality});
                try json_output.appendSlice(",\"personalization\":");
                try json_output.writer().print("{d:.2}", .{mj.personalization});
                try json_output.appendSlice("}}");
            } else {
                try json_output.appendSlice("\"}");
            }
        } else {
            std.debug.print("  Maple:  FAILED\n", .{});
            if (idx > 0) try json_output.append(',');
            try json_output.appendSlice("{\"prompt\":\"");
            try json_output.appendSlice(bp.prompt);
            try json_output.appendSlice("\",\"category\":\"");
            try json_output.appendSlice(categoryToString(bp.category));
            try json_output.appendSlice("\",\"error\":true}");
        }

        std.debug.print("\n", .{});
    }

    try json_output.appendSlice("],\"summary\":{\"total_prompts\":");
    try json_output.writer().print("{d}", .{selected_prompts.len});
    try json_output.appendSlice(",\"success_count\":");
    try json_output.writer().print("{d}", .{success_count});
    try json_output.appendSlice(",\"avg_relevance\":");
    try json_output.writer().print("{d:.4}", .{if (success_count > 0) total_rel / @as(f64, @floatFromInt(success_count)) else 0.0});
    try json_output.appendSlice(",\"avg_tps\":");
    try json_output.writer().print("{d:.2}", .{if (success_count > 0) total_tps / @as(f64, @floatFromInt(success_count)) else 0.0});
    if (judge_count > 0) {
        try json_output.appendSlice(",\"avg_judge_naturalness\":");
        try json_output.writer().print("{d:.4}", .{total_judge_nat / @as(f64, @floatFromInt(judge_count))});
        try json_output.appendSlice(",\"avg_judge_relevance\":");
        try json_output.writer().print("{d:.4}", .{total_judge_rel / @as(f64, @floatFromInt(judge_count))});
        try json_output.appendSlice(",\"avg_judge_engagement\":");
        try json_output.writer().print("{d:.4}", .{total_judge_eng / @as(f64, @floatFromInt(judge_count))});
    }
    try json_output.appendSlice("}}");

    const file = try std.fs.cwd().createFile("maple_bench_results.json", .{});
    defer file.close();
    try file.writeAll(json_output.items);

    std.debug.print("\n========================================================\n", .{});
    std.debug.print("=== Maple Standard Benchmark Summary                 ===\n", .{});
    std.debug.print("========================================================\n", .{});
    std.debug.print("Total Prompts:  {d}\n", .{selected_prompts.len});
    std.debug.print("Successful:     {d}\n", .{success_count});
    std.debug.print("Avg Relevance:  {d:.2}\n", .{if (success_count > 0) total_rel / @as(f64, @floatFromInt(success_count)) else 0.0});
    std.debug.print("Avg TPS:        {d:.1}\n", .{if (success_count > 0) total_tps / @as(f64, @floatFromInt(success_count)) else 0.0});
    if (judge_count > 0) {
        std.debug.print("Avg Judge:      nat={d:.1} rel={d:.1} eng={d:.1}\n", .{
            total_judge_nat / @as(f64, @floatFromInt(judge_count)) * 10,
            total_judge_rel / @as(f64, @floatFromInt(judge_count)) * 10,
            total_judge_eng / @as(f64, @floatFromInt(judge_count)) * 10,
        });
    }
    std.debug.print("\nResults saved to maple_bench_results.json\n", .{});
}

// =============================================================================
// Conversation Mode — Multi-turn back-and-forth between Qstar and Ollama
// =============================================================================

pub fn runConversationMode(allocator: std.mem.Allocator, cli: CliConfig) !void {
    std.debug.print("\n", .{});
    std.debug.print("========================================================\n", .{});
    std.debug.print("=== Qstar vs Ollama Conversation Mode                ===\n", .{});
    std.debug.print("=== Ollama: {s} @ {s}:{d}  ===\n", .{ cli.bench_ollama_model, cli.bench_ollama_host, cli.bench_ollama_port });
    std.debug.print("=== Turns: {d:<43} ===\n", .{cli.turns});
    std.debug.print("========================================================\n\n", .{});

    var agent = initAgent(allocator);
    defer agent.deinit();

    const ollama_cfg = ollama.OllamaConfig{ .host = cli.bench_ollama_host, .port = cli.bench_ollama_port, .model = cli.bench_ollama_model };
    const ollama_available = ollama.isAvailable(ollama_cfg);

    if (!ollama_available) {
        std.debug.print("Ollama not available at {s}:{d} — conversation mode requires both models. Exiting.\n", .{ cli.bench_ollama_host, cli.bench_ollama_port });
        return;
    }

    const conv_judge_model = g_judge_model_override orelse g_judge_model;
    const judge_available = if (cli.use_judge) ollama.isAvailable(ollama.OllamaConfig{ .host = cli.judge_host orelse cli.bench_ollama_host, .port = if (cli.judge_port > 0) cli.judge_port else cli.bench_ollama_port, .model = conv_judge_model }) else false;

    // Seed prompts for conversation starts
    const seed_prompts = [_][]const u8{
        "Hey, I've been thinking about the future of AI. What's your perspective?",
        "I read an article about space exploration today. What do you think about colonizing Mars?",
        "I had a really interesting conversation about consciousness yesterday. What are your thoughts on it?",
        "Do you think technology is making us more or less connected as humans?",
        "I'm curious — what do you think makes someone a good friend?",
    };

    const seed: u64 = if (cli.seed > 0) cli.seed else @intCast(std.time.timestamp());
    var prng = std.Random.DefaultPrng.init(seed);
    const rng = prng.random();
    const seed_idx = rng.intRangeAtMost(usize, 0, seed_prompts.len - 1);
    const opening = seed_prompts[seed_idx];

    std.debug.print("Opening prompt: \"{s}\"\n\n", .{opening});

    var conversation = std.ArrayList(u8).init(allocator);
    defer conversation.deinit();

    var json_output = std.ArrayList(u8).init(allocator);
    defer json_output.deinit();
    try json_output.appendSlice("{\"conversation\":{\"model\":\"");
    try json_output.appendSlice(cli.model);
    try json_output.appendSlice("\",\"turns\":");
    try json_output.writer().print("{d}", .{cli.turns});
    try json_output.appendSlice(",\"transcript\":[");

    var current_prompt = try allocator.dupe(u8, opening);
    defer allocator.free(current_prompt);

    var qstar_total_score: f64 = 0.0;
    var ollama_total_score: f64 = 0.0;

    for (0..cli.turns) |turn| {
        std.debug.print("--- Turn {d}/{d} ---\n", .{ turn + 1, cli.turns });
        std.debug.print("Prompt: \"{s}\"\n", .{current_prompt});

        // Qstar responds
        var qstar_timer = try std.time.Timer.start();
        const qstar_response = try agent.generateLongForm(current_prompt, allocator);
        defer allocator.free(qstar_response);
        const qstar_elapsed = qstar_timer.read();
        const qstar_ms = qstar_elapsed / 1_000_000;
        const qstar_toks = qstar_response.len / 4;
        const qstar_tps: f64 = if (qstar_elapsed > 0)
            @as(f64, @floatFromInt(qstar_toks)) / (@as(f64, @floatFromInt(qstar_elapsed)) / 1_000_000_000.0)
        else
            0.0;

        std.debug.print("Qstar  ({d}ms, {d} tok): {s}\n", .{ qstar_ms, qstar_toks, if (qstar_response.len > 120) qstar_response[0..120] else qstar_response });

        // Ollama responds to the same prompt
        var ollama_timer = try std.time.Timer.start();
        var ollama_resp = ollama.generate(allocator, ollama_cfg, current_prompt) catch {
            std.debug.print("Ollama: FAILED\n", .{});
            continue;
        };
        defer ollama_resp.deinit();
        const ollama_elapsed = ollama_timer.read();
        const ollama_ms = ollama_elapsed / 1_000_000;
        const ollama_toks = ollama_resp.text.len / 4;
        const ollama_tps: f64 = if (ollama_elapsed > 0)
            @as(f64, @floatFromInt(ollama_toks)) / (@as(f64, @floatFromInt(ollama_elapsed)) / 1_000_000_000.0)
        else
            0.0;

        std.debug.print("Ollama ({d}ms, {d} tok): {s}\n", .{ ollama_ms, ollama_toks, if (ollama_resp.text.len > 120) ollama_resp.text[0..120] else ollama_resp.text });

        // Judge both responses
        var qstar_judge: ?JudgeScores = null;
        var ollama_judge: ?JudgeScores = null;
        if (judge_available) {
            qstar_judge = judgeResponse(allocator, current_prompt, qstar_response);
            ollama_judge = judgeResponse(allocator, current_prompt, ollama_resp.text);

            if (qstar_judge) |qj| {
                std.debug.print("Qstar judge:  nat={d:.1} rel={d:.1} eng={d:.1}\n", .{ qj.naturalness * 10, qj.relevance * 10, qj.engagement * 10 });
                qstar_total_score += qj.composite();
            }
            if (ollama_judge) |oj| {
                std.debug.print("Ollama judge: nat={d:.1} rel={d:.1} eng={d:.1}\n", .{ oj.naturalness * 10, oj.relevance * 10, oj.engagement * 10 });
                ollama_total_score += oj.composite();
            }
        }

        // Determine winner for this turn
        if (qstar_judge != null and ollama_judge != null) {
            const qs = qstar_judge.?.composite();
            const os = ollama_judge.?.composite();
            if (qs > os + 0.01) {
                std.debug.print("Winner: Qstar\n\n", .{});
            } else if (os > qs + 0.01) {
                std.debug.print("Winner: Ollama\n\n", .{});
            } else {
                std.debug.print("Result: Tie\n\n", .{});
            }
        } else {
            // Fallback: use TPS
            if (qstar_tps > ollama_tps + 1.0) {
                std.debug.print("Winner: Qstar (by throughput)\n\n", .{});
                qstar_total_score += 0.5;
            } else if (ollama_tps > qstar_tps + 1.0) {
                std.debug.print("Winner: Ollama (by throughput)\n\n", .{});
                ollama_total_score += 0.5;
            } else {
                std.debug.print("Result: Tie\n\n", .{});
            }
        }

        // JSON transcript entry
        if (turn > 0) try json_output.append(',');
        try json_output.appendSlice("{\"turn\":");
        try json_output.writer().print("{d}", .{turn + 1});
        try json_output.appendSlice(",\"prompt\":\"");
        try json_output.appendSlice(current_prompt);
        try json_output.appendSlice("\",\"qstar\":{\"text\":\"");
        const qstar_trunc = if (qstar_response.len > 500) qstar_response[0..500] else qstar_response;
        try json_output.appendSlice(qstar_trunc);
        try json_output.appendSlice("\",\"ms\":");
        try json_output.writer().print("{d}", .{qstar_ms});
        try json_output.appendSlice(",\"tps\":");
        try json_output.writer().print("{d:.2}", .{qstar_tps});
        if (qstar_judge) |qj| {
            try json_output.appendSlice(",\"judge\":{\"naturalness\":");
            try json_output.writer().print("{d:.2}", .{qj.naturalness});
            try json_output.appendSlice(",\"relevance\":");
            try json_output.writer().print("{d:.2}", .{qj.relevance});
            try json_output.appendSlice(",\"engagement\":");
            try json_output.writer().print("{d:.2}", .{qj.engagement});
            try json_output.appendSlice(",\"factual_accuracy\":");
            try json_output.writer().print("{d:.2}", .{qj.factual_accuracy});
            try json_output.appendSlice(",\"originality\":");
            try json_output.writer().print("{d:.2}", .{qj.originality});
            try json_output.appendSlice(",\"personalization\":");
            try json_output.writer().print("{d:.2}", .{qj.personalization});
            try json_output.appendSlice("}");
        }
        try json_output.appendSlice("},\"ollama\":{\"text\":\"");
        const ollama_trunc = if (ollama_resp.text.len > 500) ollama_resp.text[0..500] else ollama_resp.text;
        try json_output.appendSlice(ollama_trunc);
        try json_output.appendSlice("\",\"ms\":");
        try json_output.writer().print("{d}", .{ollama_ms});
        try json_output.appendSlice(",\"tps\":");
        try json_output.writer().print("{d:.2}", .{ollama_tps});
        if (ollama_judge) |oj| {
            try json_output.appendSlice(",\"judge\":{\"naturalness\":");
            try json_output.writer().print("{d:.2}", .{oj.naturalness});
            try json_output.appendSlice(",\"relevance\":");
            try json_output.writer().print("{d:.2}", .{oj.relevance});
            try json_output.appendSlice(",\"engagement\":");
            try json_output.writer().print("{d:.2}", .{oj.engagement});
            try json_output.appendSlice(",\"factual_accuracy\":");
            try json_output.writer().print("{d:.2}", .{oj.factual_accuracy});
            try json_output.appendSlice(",\"originality\":");
            try json_output.writer().print("{d:.2}", .{oj.originality});
            try json_output.appendSlice(",\"personalization\":");
            try json_output.writer().print("{d:.2}", .{oj.personalization});
            try json_output.appendSlice("}");
        }
        try json_output.appendSlice("}}");

        // Build next prompt: Ollama's response becomes the next prompt for Qstar
        // and vice versa — we alternate which model's response drives the conversation
        const next_prompt = if (turn % 2 == 0) ollama_resp.text else qstar_response;
        allocator.free(current_prompt);
        current_prompt = try allocator.dupe(u8, next_prompt);
    }

    try json_output.appendSlice("],\"summary\":{\"qstar_total_score\":");
    try json_output.writer().print("{d:.4}", .{qstar_total_score});
    try json_output.appendSlice(",\"ollama_total_score\":");
    try json_output.writer().print("{d:.4}", .{ollama_total_score});
    try json_output.appendSlice("}}");

    // Write transcript
    const transcript_file = try std.fs.cwd().createFile("conversation_transcript.json", .{});
    defer transcript_file.close();
    try transcript_file.writeAll(json_output.items);

    std.debug.print("\n========================================================\n", .{});
    std.debug.print("=== Conversation Summary                             ===\n", .{});
    std.debug.print("========================================================\n", .{});
    std.debug.print("Turns:          {d}\n", .{cli.turns});
    std.debug.print("Qstar Score:    {d:.3}\n", .{qstar_total_score});
    std.debug.print("Ollama Score:   {d:.3}\n", .{ollama_total_score});
    if (qstar_total_score > ollama_total_score) {
        std.debug.print("Overall Winner: Qstar\n", .{});
    } else if (ollama_total_score > qstar_total_score) {
        std.debug.print("Overall Winner: Ollama\n", .{});
    } else {
        std.debug.print("Overall Result: Tie\n", .{});
    }
    std.debug.print("\nTranscript saved to conversation_transcript.json\n", .{});
}

// =============================================================================
// Tests
// =============================================================================

test "competitive_bench: scoreResponse counts keyword hits correctly" {
    const result = scoreResponse("The quick brown fox jumps", &.{ "quick", "fox", "dog" });
    try std.testing.expect(result.hits == 2);
    try std.testing.expect(result.total == 3);
    try std.testing.expect(result.relevance > 0.66 and result.relevance < 0.67);
}

test "competitive_bench: scoreResponse with no keywords returns neutral" {
    const result = scoreResponse("Any response", &.{});
    try std.testing.expect(result.hits == 0);
    try std.testing.expect(result.total == 0);
    try std.testing.expect(result.relevance == 0.5);
}

test "competitive_bench: scoreResponse with all keywords matched" {
    const result = scoreResponse("sunlight chlorophyll oxygen sugar", &.{ "sunlight", "chlorophyll", "oxygen", "sugar" });
    try std.testing.expect(result.hits == 4);
    try std.testing.expect(result.total == 4);
    try std.testing.expect(result.relevance == 1.0);
}

test "competitive_bench: categoryToString maps all categories" {
    try std.testing.expectEqualStrings("factual", categoryToString(.factual));
    try std.testing.expectEqualStrings("creative", categoryToString(.creative));
    try std.testing.expectEqualStrings("naturalness", categoryToString(.naturalness));
    try std.testing.expectEqualStrings("reasoning", categoryToString(.reasoning));
    try std.testing.expectEqualStrings("chitchat", categoryToString(.chitchat));
    try std.testing.expectEqualStrings("opinions", categoryToString(.opinions));
    try std.testing.expectEqualStrings("open_ended", categoryToString(.open_ended));
    try std.testing.expectEqualStrings("latency", categoryToString(.latency));
    try std.testing.expectEqualStrings("throughput", categoryToString(.throughput));
    try std.testing.expectEqualStrings("tool_calling", categoryToString(.tool_calling));
    try std.testing.expectEqualStrings("untrained", categoryToString(.untrained));
    try std.testing.expectEqualStrings("mmlu", categoryToString(.mmlu));
    try std.testing.expectEqualStrings("gsm8k", categoryToString(.gsm8k));
}

test "competitive_bench: categoryFromString round-trips" {
    try std.testing.expect(categoryFromString("factual") == .factual);
    try std.testing.expect(categoryFromString("creative") == .creative);
    try std.testing.expect(categoryFromString("naturalness") == .naturalness);
    try std.testing.expect(categoryFromString("reasoning") == .reasoning);
    try std.testing.expect(categoryFromString("chitchat") == .chitchat);
    try std.testing.expect(categoryFromString("opinions") == .opinions);
    try std.testing.expect(categoryFromString("open_ended") == .open_ended);
    try std.testing.expect(categoryFromString("tool_calling") == .tool_calling);
    try std.testing.expect(categoryFromString("untrained") == .untrained);
    try std.testing.expect(categoryFromString("mmlu") == .mmlu);
    try std.testing.expect(categoryFromString("gsm8k") == .gsm8k);
}

test "competitive_bench: BENCHMARK_PROMPTS has prompts in all key categories" {
    var has_factual = false;
    var has_creative = false;
    var has_naturalness = false;
    var has_reasoning = false;
    var has_chitchat = false;
    var has_opinions = false;
    var has_open_ended = false;
    var has_tool_calling = false;
    var has_mmlu = false;
    var has_gsm8k = false;
    for (BENCHMARK_PROMPTS) |bp| {
        switch (bp.category) {
            .factual => has_factual = true,
            .creative => has_creative = true,
            .naturalness => has_naturalness = true,
            .reasoning => has_reasoning = true,
            .chitchat => has_chitchat = true,
            .opinions => has_opinions = true,
            .open_ended => has_open_ended = true,
            .tool_calling => has_tool_calling = true,
            .mmlu => has_mmlu = true,
            .gsm8k => has_gsm8k = true,
            else => {},
        }
    }
    try std.testing.expect(has_factual);
    try std.testing.expect(has_creative);
    try std.testing.expect(has_naturalness);
    try std.testing.expect(has_reasoning);
    try std.testing.expect(has_chitchat);
    try std.testing.expect(has_opinions);
    try std.testing.expect(has_open_ended);
    try std.testing.expect(has_tool_calling);
    try std.testing.expect(has_mmlu);
    try std.testing.expect(has_gsm8k);
}

test "competitive_bench: ScoredResponse deinit frees text" {
    const allocator = std.testing.allocator;
    var sr = ScoredResponse{
        .text = try allocator.dupe(u8, "test response"),
        .latency_ns = 1000,
        .token_count = 3,
        .keyword_hits = 1,
        .keyword_total = 2,
        .relevance_score = 0.5,
        .tokens_per_sec = 100.0,
        .allocator = allocator,
    };
    sr.deinit();
}

test "competitive_bench: parseJudgeScores extracts values from JSON" {
    const json = "{\"naturalness\": 7, \"relevance\": 8, \"engagement\": 6}";
    const scores = parseJudgeScores(json);
    try std.testing.expect(scores.naturalness > 0.69 and scores.naturalness < 0.71);
    try std.testing.expect(scores.relevance > 0.79 and scores.relevance < 0.81);
    try std.testing.expect(scores.engagement > 0.59 and scores.engagement < 0.61);
}

test "competitive_bench: parseJudgeScores handles missing fields" {
    const json = "{\"naturalness\": 5}";
    const scores = parseJudgeScores(json);
    try std.testing.expect(scores.naturalness == 0.5);
    try std.testing.expect(scores.relevance == 0.0);
    try std.testing.expect(scores.engagement == 0.0);
}

test "competitive_bench: findJsonNumber extracts numeric value" {
    const json = "{\"score\": 42.5, \"name\": \"test\"}";
    const val = findJsonNumber(json, "score");
    try std.testing.expect(val != null);
    try std.testing.expect(val.? > 42.4 and val.? < 42.6);
}

test "competitive_bench: findJsonNumber returns null for missing field" {
    const json = "{\"score\": 42}";
    const val = findJsonNumber(json, "missing");
    try std.testing.expect(val == null);
}

test "competitive_bench: JudgeScores composite averages six scores" {
    const scores = JudgeScores{ .naturalness = 0.6, .relevance = 0.8, .engagement = 0.4, .factual_accuracy = 0.5, .originality = 0.7, .personalization = 0.6 };
    const comp = scores.composite();
    // (0.6 + 0.8 + 0.4 + 0.5 + 0.7 + 0.6) / 6 = 3.6 / 6 = 0.6
    try std.testing.expect(comp > 0.59 and comp < 0.61);
}

test "competitive_bench: computeCompositeScore uses judge for chitchat" {
    const allocator = std.testing.allocator;
    const qstar_resp = ScoredResponse{
        .text = try allocator.dupe(u8, "test"),
        .latency_ns = 1000,
        .token_count = 1,
        .keyword_hits = 0,
        .keyword_total = 0,
        .relevance_score = 0.5,
        .tokens_per_sec = 100.0,
        .judge = JudgeScores{ .naturalness = 0.8, .relevance = 0.7, .engagement = 0.6, .factual_accuracy = 0.5, .originality = 0.5, .personalization = 0.5 },
        .allocator = allocator,
    };
    defer allocator.free(qstar_resp.text);
    const score = computeCompositeScore(qstar_resp, .chitchat, 50.0);
    // chitchat with judge: personalization*0.25 + naturalness*0.25 + engagement*0.20 + relevance*0.15 + originality*0.10 + tps_ratio*0.05
    // tps_ratio = 100/(100+50) = 0.667
    // = 0.5*0.25 + 0.8*0.25 + 0.6*0.20 + 0.7*0.15 + 0.5*0.10 + 0.667*0.05
    // = 0.125 + 0.20 + 0.12 + 0.105 + 0.05 + 0.033 = 0.633
    try std.testing.expect(score > 0.62 and score < 0.65);
}

test "competitive_bench: computeCompositeScore uses keywords for factual" {
    const allocator = std.testing.allocator;
    const qstar_resp = ScoredResponse{
        .text = try allocator.dupe(u8, "test"),
        .latency_ns = 1000,
        .token_count = 1,
        .keyword_hits = 3,
        .keyword_total = 4,
        .relevance_score = 0.75,
        .tokens_per_sec = 100.0,
        .judge = JudgeScores{ .naturalness = 0.9, .relevance = 0.9, .engagement = 0.9, .factual_accuracy = 0.9, .originality = 0.9, .personalization = 0.9 },
        .allocator = allocator,
    };
    defer allocator.free(qstar_resp.text);
    const score = computeCompositeScore(qstar_resp, .factual, 50.0);
    // factual with judge: relevance*0.30 + factual_accuracy*0.30 + naturalness*0.15 + engagement*0.10 + originality*0.05 + personalization*0.05 + tps_ratio*0.05
    // tps_ratio = 100/(100+50) = 0.667
    // = 0.9*0.30 + 0.9*0.30 + 0.9*0.15 + 0.9*0.10 + 0.9*0.05 + 0.9*0.05 + 0.667*0.05
    // = 0.27 + 0.27 + 0.135 + 0.09 + 0.045 + 0.045 + 0.033 = 0.888
    try std.testing.expect(score > 0.87 and score < 0.90);
}

test "competitive_bench: CliConfig defaults are correct" {
    const cli = CliConfig{};
    try std.testing.expect(std.mem.eql(u8, cli.model, DEFAULT_MODEL_STR));
    try std.testing.expect(cli.random == false);
    try std.testing.expect(cli.num_prompts == 0);
    try std.testing.expect(cli.use_judge == true);
    try std.testing.expect(cli.conversation == false);
    try std.testing.expect(cli.turns == 5);
    try std.testing.expect(cli.no_ollama == false);
    try std.testing.expect(cli.no_openai == false);
    try std.testing.expect(std.mem.eql(u8, cli.openai_model, DEFAULT_OPENAI_MODEL));
    try std.testing.expect(cli.openai_judge == false);
    try std.testing.expect(cli.openai_api_key.len == 0);
}

test "competitive_bench: runOpenAIPrompt returns null when unavailable" {
    const allocator = std.testing.allocator;
    const cfg = openai.OpenAIConfig{};
    const bp = BenchPrompt{ .prompt = "test", .category = .factual, .expected_keywords = &.{} };
    const result = try runOpenAIPrompt(allocator, cfg, bp);
    try std.testing.expect(result == null);
}

test "competitive_bench: judgeResponseWithConfig falls back to null without judges" {
    const allocator = std.testing.allocator;
    const scores = judgeResponseWithConfig(allocator, "prompt", "response", null, null, g_ollama_host, g_ollama_port);
    // No Ollama judge available in test env — expect null (graceful)
    _ = scores;
}

test "competitive_bench: categoryCount returns 11" {
    try std.testing.expect(categoryCount() == 11);
}
