#!/usr/bin/env python3
"""Convert dictionary JSON datasets to plain-text sentence format for Qstar corpus ingestion."""

import json
import os
import sys
import glob

def convert_wordnet_2025(input_dir, output_file):
    """Convert WordNet 2025+ JSON files to text sentences."""
    count = 0
    with open(output_file, 'w', encoding='utf-8') as out:
        for json_path in sorted(glob.glob(os.path.join(input_dir, "*.json"))):
            if "entries-" in os.path.basename(json_path) or "frames" in os.path.basename(json_path):
                continue
            with open(json_path, 'r', encoding='utf-8') as f:
                try:
                    data = json.load(f)
                except json.JSONDecodeError:
                    continue
            for synset_id, entry in data.items():
                pos = entry.get("partOfSpeech", "n")
                members = entry.get("members", [])
                definitions = entry.get("definition", [])
                if not members or not definitions:
                    continue
                word = members[0]
                for defn in definitions:
                    line = f"{word} ({pos}): {defn}"
                    out.write(line + ".\n")
                    count += 1
                    # Add synonyms as separate entries
                    for syn in members[1:]:
                        out.write(f"{syn} ({pos}): same as {word}. {defn}.\n")
                        count += 1
    print(f"WordNet 2025: {count} sentences written to {output_file}")
    return count

def convert_wiktionary_open(input_dir, output_file):
    """Convert Open Dictionary (Wiktionary) JSON files to text sentences."""
    count = 0
    with open(output_file, 'w', encoding='utf-8') as out:
        api_dir = os.path.join(input_dir, "api")
        for letter_dir in sorted(os.listdir(api_dir)):
            letter_path = os.path.join(api_dir, letter_dir)
            if not os.path.isdir(letter_path):
                continue
            for json_file in sorted(glob.glob(os.path.join(letter_path, "*.json"))):
                with open(json_file, 'r', encoding='utf-8') as f:
                    try:
                        data = json.load(f)
                    except json.JSONDecodeError:
                        continue
                for word, entry in data.items():
                    etymologies = entry.get("etymologies", [])
                    for etym in etymologies:
                        parts = etym.get("partsOfSpeech", [])
                        for pos_entry in parts:
                            pos = pos_entry.get("partOfSpeech", "unknown").lower()
                            senses = pos_entry.get("senses", [])
                            for sense in senses:
                                definition = sense.get("sense", "")
                                examples = sense.get("examples", [])
                                if definition:
                                    line = f"{word} ({pos}): {definition}"
                                    out.write(line + ".\n")
                                    count += 1
                                    for ex in examples:
                                        out.write(f"Example of {word}: {ex}.\n")
                                        count += 1
    print(f"Wiktionary Open: {count} sentences written to {output_file}")
    return count

def convert_oxford_corpus(input_file, output_file):
    """Convert Oxford Corpus JSON to text sentences."""
    count = 0
    with open(input_file, 'r', encoding='utf-8') as f:
        data = json.load(f)
    with open(output_file, 'w', encoding='utf-8') as out:
        for entry in data:
            word = entry.get("word", "")
            pos = entry.get("pos", "n")
            definitions = entry.get("definitions", [])
            for defn in definitions:
                line = f"{word} ({pos}): {defn}"
                out.write(line + ".\n")
                count += 1
    print(f"Oxford Corpus: {count} sentences written to {output_file}")
    return count

def convert_wordnet_31(input_file, output_file):
    """Convert WordNet 3.1 JSON to text sentences."""
    count = 0
    with open(input_file, 'r', encoding='utf-8') as f:
        data = json.load(f)
    with open(output_file, 'w', encoding='utf-8') as out:
        synsets = data.get("synset", data)
        for synset_id, entry in synsets.items():
            pos = entry.get("pos", "n")
            words = entry.get("word", [])
            gloss = entry.get("gloss", "")
            if not words:
                continue
            # Extract definition from gloss (first sentence before example)
            definition = gloss.split(";")[0].split('"')[0].strip() if gloss else ""
            if not definition:
                continue
            word = words[0]
            out.write(f"{word} ({pos}): {definition}.\n")
            count += 1
            for syn in words[1:]:
                out.write(f"{syn} ({pos}): same as {word}. {definition}.\n")
                count += 1
    print(f"WordNet 3.1: {count} sentences written to {output_file}")
    return count

def main():
    base = "/home/admpaul/CascadeProjects/basic/qstar-llm"
    output_dir = os.path.join(base, "datasets/dictionaries")
    os.makedirs(output_dir, exist_ok=True)

    total = 0

    # WordNet 2025+
    wn2025_dir = "/tmp/wordnet_2025_extracted"
    if os.path.isdir(wn2025_dir):
        total += convert_wordnet_2025(wn2025_dir, os.path.join(output_dir, "wordnet_2025.txt"))

    # Wiktionary Open Dictionary
    wikt_dir = "/tmp/open_dictionary"
    if os.path.isdir(wikt_dir):
        total += convert_wiktionary_open(wikt_dir, os.path.join(output_dir, "wiktionary_open.txt"))

    # Oxford Corpus
    oxford_file = "/tmp/oxford_corpus/oxford_corpus.json"
    if os.path.isfile(oxford_file):
        total += convert_oxford_corpus(oxford_file, os.path.join(output_dir, "oxford_corpus.txt"))

    # WordNet 3.1
    wn31_file = "/tmp/wordnet31.json"
    if os.path.isfile(wn31_file):
        total += convert_wordnet_31(wn31_file, os.path.join(output_dir, "wordnet_31.txt"))

    print(f"\nTotal: {total} sentences written to {output_dir}")
    # Print file sizes
    for f in sorted(os.listdir(output_dir)):
        path = os.path.join(output_dir, f)
        if os.path.isfile(path):
            size = os.path.getsize(path)
            print(f"  {f}: {size / 1024 / 1024:.1f} MB")

if __name__ == "__main__":
    main()
