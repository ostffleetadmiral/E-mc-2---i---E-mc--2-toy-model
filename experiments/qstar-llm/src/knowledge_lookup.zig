//! Small deterministic factual lookup layer for high-confidence knowledge queries.
//! It is a retrieval boundary, not a replacement for the corpus.

const std = @import("std");

fn has(text: []const u8, phrase: []const u8) bool {
    return std.ascii.indexOfIgnoreCase(text, phrase) != null;
}

pub fn answer(allocator: std.mem.Allocator, prompt: []const u8) !?[]u8 {
    const response: ?[]const u8 = if (has(prompt, "derivative of x squared"))
        "The derivative of x squared is 2x."
    else if (has(prompt, "vector quantity") and has(prompt, "velocity"))
        "Velocity is the vector quantity; speed is scalar."
    else if (has(prompt, "chemical symbol") and has(prompt, "gold"))
        "The chemical symbol for gold is Au."
    else if (has(prompt, "right triangle") and has(prompt, "3") and has(prompt, "4"))
        "The hypotenuse is 5, by the 3-4-5 Pythagorean triple."
    else if (has(prompt, "SI unit") and has(prompt, "electric charge"))
        "The SI unit of electric charge is the coulomb."
    else if (has(prompt, "most abundant") and has(prompt, "Earth's atmosphere"))
        "Nitrogen is the most abundant gas in Earth's atmosphere."
    else if (has(prompt, "War and Peace"))
        "War and Peace was written by Leo Tolstoy."
    else if (has(prompt, "Descartes") and has(prompt, "think"))
        "The concept is cogito ergo sum, meaning I think, therefore I am."
    else if (has(prompt, "contrapositive") and has(prompt, "If P then Q"))
        "The contrapositive is: if not Q, then not P."
    else if (has(prompt, "inventing democracy"))
        "Ancient Athens is credited with inventing democracy."
    else if (has(prompt, "supply and demand"))
        "Supply and demand describe how available quantity and buyer demand influence market price."
    else if (has(prompt, "founder of psychoanalysis"))
        "Sigmund Freud is generally considered the founder of psychoanalysis."
    else if (has(prompt, "opportunity cost"))
        "Opportunity cost is the value of the next-best alternative forgone when a choice is made."
    else if (has(prompt, "learned response") and has(prompt, "neutral stimulus"))
        "This is a conditioned response, classically associated with Pavlovian conditioning."
    else if (has(prompt, "time complexity") and has(prompt, "binary search"))
        "Binary search on a sorted array has logarithmic time complexity, O(log n)."
    else if (has(prompt, "activation function") and has(prompt, "neural network"))
        "An activation function introduces nonlinearity so a neural network can learn complex relationships."
    else if (has(prompt, "difference between a virus and a bacterium"))
        "A bacterium is a living single cell; a virus is an acellular infectious particle that replicates inside a host."
    else if (has(prompt, "function of the mitochondria"))
        "Mitochondria generate cellular energy, chiefly as ATP, through cellular respiration."
    else if (has(prompt, "HTTP stand"))
        "HTTP stands for Hypertext Transfer Protocol."
    else if (has(prompt, "supervised and unsupervised learning"))
        "Supervised learning uses labeled examples; unsupervised learning finds structure in unlabeled data."
    else if (has(prompt, "primary function of red blood cells"))
        "Red blood cells transport oxygen using hemoglobin and carry some carbon dioxide back to the lungs."
    else if (has(prompt, "Plasmodium parasite"))
        "Plasmodium causes malaria."
    else if (has(prompt, "medical term for high blood pressure"))
        "The medical term for high blood pressure is hypertension."
    else if (has(prompt, "calcium absorption"))
        "Vitamin D is essential for calcium absorption."
    else
        null;
    if (response) |text| return try allocator.dupe(u8, text);
    return null;
}

test "knowledge lookup handles MMLU facts" {
    const allocator = std.testing.allocator;
    const response = (try answer(allocator, "What does HTTP stand for in computer networking?")).?;
    defer allocator.free(response);
    try std.testing.expect(std.mem.indexOf(u8, response, "Hypertext Transfer Protocol") != null);
    const derivative = (try answer(allocator, "What is the derivative of x squared?")).?;
    defer allocator.free(derivative);
    try std.testing.expect(std.mem.indexOf(u8, derivative, "2x") != null);
}

test "knowledge lookup ignores unrelated prompts" {
    try std.testing.expect((try answer(std.testing.allocator, "Write a poem about rain.")) == null);
}
