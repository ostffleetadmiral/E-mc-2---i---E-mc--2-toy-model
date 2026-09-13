# Qstar Tools Reference

**Version 3.2.0** | 58 registered tools | 44 tool tests | `zig build tool-test`

This document provides a complete reference for all tools available in the Qstar tool calling engine (`src/tools.zig`).

## Tool Calling Syntax

Qstar supports two markup formats for invoking tools from agent text:

1. `[[{"name":"tool_name","arguments":{...}}]]`
2. `<tool_call>{"name":"tool_name","arguments":{...}}</tool_call>`

The `parseToolCall()` function extracts the tool name and arguments JSON from either format.

---

## Original Tools (3)

### 1. `calculate`

Executes high-precision fixed-point mathematical operations using Q32.32 arithmetic.

**Parameters:**

| Name | Type | Required | Description |
|------|------|----------|-------------|
| `op` | string | Yes | Operation: `add`, `sub`, `mul`, `div`, `sqrt`, `exp`, `sin`, `cos` |
| `a` | number | Yes | First operand |
| `b` | number | No | Second operand (optional for `sqrt`/`exp`/`sin`/`cos`) |

**Example:** `{"op":"mul","a":7,"b":6}` → `{"result":42.000000}`

---

### 2. `lattice_node`

Queries the E0 lattice for coordinate information at a given (x, y, z) position.

**Parameters:**

| Name | Type | Required | Description |
|------|------|----------|-------------|
| `x` | integer | Yes | X coordinate |
| `y` | integer | Yes | Y coordinate |
| `z` | integer | Yes | Z coordinate |

**Example:** `{"x":3,"y":0,"z":0}` → `{"is_e0":true,"e_value":3,"is_boundary":false}`

---

### 3. `quantum_simulate`

Simulates quantum circuits with configurable qubit count and circuit type.

**Parameters:**

| Name | Type | Required | Description |
|------|------|----------|-------------|
| `circuit` | string | Yes | Circuit type: `bell`, `ghz`, `grover` |
| `qubits` | integer | No | Number of qubits (2..8, default 2) |

**Example:** `{"circuit":"bell","qubits":2}` → `{"entangled":true,"probabilities":[0.5,0.5],...}`

---

## Core Utility Tools (13)

### 4. `file_read`

Reads the contents of a file from the filesystem.

**Parameters:**

| Name | Type | Required | Description |
|------|------|----------|-------------|
| `path` | string | Yes | File path to read |

**Example:** `{"path":"/tmp/data.txt"}` → `{"content":"...","size":1234}`

---

### 5. `file_write`

Writes content to a file on the filesystem.

**Parameters:**

| Name | Type | Required | Description |
|------|------|----------|-------------|
| `path` | string | Yes | File path to write |
| `content` | string | Yes | Content to write |

**Example:** `{"path":"/tmp/out.txt","content":"Hello"}` → `{"status":"written","bytes":5}`

---

### 6. `file_list`

Lists files in a directory.

**Parameters:**

| Name | Type | Required | Description |
|------|------|----------|-------------|
| `path` | string | No | Directory path (default: current directory) |

**Example:** `{"path":"/tmp"}` → `{"files":["a.txt","b.log",...]}`

---

### 7. `http_fetch`

Performs an HTTP GET request to a URL and returns the response body.

**Parameters:**

| Name | Type | Required | Description |
|------|------|----------|-------------|
| `url` | string | Yes | URL to fetch |

**Example:** `{"url":"http://example.com"}` → `{"status":200,"body":"..."}`

---

### 8. `shell_exec`

Executes a shell command and returns stdout.

**Parameters:**

| Name | Type | Required | Description |
|------|------|----------|-------------|
| `command` | string | Yes | Shell command to execute |

**Example:** `{"command":"echo hello"}` → `{"stdout":"hello\n","exit_code":0}`

---

### 9. `time_now`

Returns the current timestamp in multiple formats.

**Parameters:** None

**Example:** `{}` → `{"unix":1700000000,"iso":"2024-01-01T00:00:00Z"}`

---

### 10. `uuid_generate`

Generates a random UUID v4.

**Parameters:** None

**Example:** `{}` → `{"uuid":"550e8400-e29b-41d4-a716-446655440000"}`

---

### 11. `base64_encode`

Encodes a string to base64.

**Parameters:**

| Name | Type | Required | Description |
|------|------|----------|-------------|
| `input` | string | Yes | String to encode |

**Example:** `{"input":"Hello"}` → `{"encoded":"SGVsbG8="}`

---

### 12. `base64_decode`

Decodes a base64 string.

**Parameters:**

| Name | Type | Required | Description |
|------|------|----------|-------------|
| `input` | string | Yes | Base64 string to decode |

**Example:** `{"input":"SGVsbG8="}` → `{"decoded":"Hello"}`

---

### 13. `hash_compute`

Computes a hash of the input data using the specified algorithm.

**Parameters:**

| Name | Type | Required | Description |
|------|------|----------|-------------|
| `input` | string | Yes | Data to hash |
| `algorithm` | string | No | Hash algorithm: `sha256`, `crc32` (default: `sha256`) |

**Example:** `{"input":"test"}` → `{"hash":"9f86d081884c7d65..."}`

---

### 14. `json_validate`

Validates a JSON string and reports any parse errors.

**Parameters:**

| Name | Type | Required | Description |
|------|------|----------|-------------|
| `input` | string | Yes | JSON string to validate |

**Example:** `{"input":"{\"a\":1}"}` → `{"valid":true}`

---

### 15. `json_format`

Formats/pretty-prints a JSON string with indentation.

**Parameters:**

| Name | Type | Required | Description |
|------|------|----------|-------------|
| `input` | string | Yes | JSON string to format |
| `indent` | integer | No | Indentation spaces (default: 2) |

**Example:** `{"input":"{\"a\":1}"}` → `{"formatted":"{\n  \"a\": 1\n}"}`

---

### 16. `string_replace`

Replaces all occurrences of a substring within a string.

**Parameters:**

| Name | Type | Required | Description |
|------|------|----------|-------------|
| `input` | string | Yes | Source string |
| `find` | string | Yes | Substring to find |
| `replace` | string | Yes | Replacement string |

**Example:** `{"input":"hello world","find":"world","replace":"Qstar"}` → `{"result":"hello Qstar"}`

---

## Text Processing Tools (7)

### 17. `text_summarize`

Generates a summary of the input text by extracting key sentences.

**Parameters:**

| Name | Type | Required | Description |
|------|------|----------|-------------|
| `text` | string | Yes | Text to summarize |
| `max_sentences` | integer | No | Maximum sentences in summary (default: 3) |

**Example:** `{"text":"Long text...","max_sentences":2}` → `{"summary":"Key sentence 1. Key sentence 2."}`

---

### 18. `sentiment_analyze`

Performs sentiment analysis on the input text.

**Parameters:**

| Name | Type | Required | Description |
|------|------|----------|-------------|
| `text` | string | Yes | Text to analyze |

**Example:** `{"text":"I love this!"}` → `{"sentiment":"positive","score":0.8}`

---

### 19. `ner_extract`

Performs named entity recognition on the input text.

**Parameters:**

| Name | Type | Required | Description |
|------|------|----------|-------------|
| `text` | string | Yes | Text to analyze |

**Example:** `{"text":"Apple is in Cupertino"}` → `{"entities":[{"text":"Apple","type":"ORG"},...]}`

---

### 20. `text_classify`

Classifies text into categories based on keyword matching.

**Parameters:**

| Name | Type | Required | Description |
|------|------|----------|-------------|
| `text` | string | Yes | Text to classify |

**Example:** `{"text":"Quantum computing uses qubits"}` → `{"category":"science/quantum"}`

---

### 21. `word_count`

Counts words, characters, and sentences in the input text.

**Parameters:**

| Name | Type | Required | Description |
|------|------|----------|-------------|
| `text` | string | Yes | Text to count |

**Example:** `{"text":"Hello world. Test."}` → `{"words":3,"characters":17,"sentences":2}`

---

### 22. `text_diff`

Computes a line-level diff between two text strings.

**Parameters:**

| Name | Type | Required | Description |
|------|------|----------|-------------|
| `text_a` | string | Yes | First text |
| `text_b` | string | Yes | Second text |

**Example:** `{"text_a":"line1\nline2","text_b":"line1\nline3"}` → `{"diff":"- line2\n+ line3"}`

---

### 23. `language_detect`

Detects the language of the input text using character frequency analysis.

**Parameters:**

| Name | Type | Required | Description |
|------|------|----------|-------------|
| `text` | string | Yes | Text to analyze |

**Example:** `{"text":"Bonjour le monde"}` → `{"language":"fr","confidence":0.85}`

---

## Knowledge & Retrieval Tools (9)

### 24. `wikipedia_lookup`

Searches Wikipedia dataset files for the given query.

**Parameters:**

| Name | Type | Required | Description |
|------|------|----------|-------------|
| `query` | string | Yes | Search query |

**Example:** `{"query":"quantum mechanics"}` → `{"snippet":"...","source":"wikipedia"}`

---

### 25. `dictionary_lookup`

Searches dictionary dataset files for word definitions.

**Parameters:**

| Name | Type | Required | Description |
|------|------|----------|-------------|
| `query` | string | Yes | Word to look up |

**Example:** `{"query":"entropy"}` → `{"snippet":"...","source":"dictionary"}`

---

### 26. `law_lookup`

Searches legal corpus dataset files for legal terms and cases.

**Parameters:**

| Name | Type | Required | Description |
|------|------|----------|-------------|
| `query` | string | Yes | Legal query |

**Example:** `{"query":"habeas corpus"}` → `{"snippet":"...","source":"law"}`

---

### 27. `rag_search`

Performs retrieval-augmented generation search over local knowledge files.

**Parameters:**

| Name | Type | Required | Description |
|------|------|----------|-------------|
| `query` | string | Yes | Search query |

**Example:** `{"query":"neural networks"}` → `{"snippet":"...","source":"rag"}`

---

### 28. `kg_query`

Queries the discrete E0 lattice-grounded Knowledge Graph for relational triplets and neighbors.

**Parameters:**

| Name | Type | Required | Description |
|------|------|----------|-------------|
| `entity` | string | Yes | Entity or subject term to query in knowledge graph |
| `predicate` | string | No | Optional relation/predicate filter |

**Example:** `{"entity":"photosynthesis","predicate":"uses"}` → `{"results":[{"subject":"photosynthesis","predicate":"uses","object":"sunlight"}]}`

---

### 29. `db_query`

Queries structured key-value databases, local schemas, and reference datasets.

**Parameters:**

| Name | Type | Required | Description |
|------|------|----------|-------------|
| `key` | string | Yes | Target key or search term |
| `source` | string | No | Database source name or category |

**Example:** `{"key":"entropy","source":"physics"}` → `{"result":"Entropy is a measure of disorder..."}`

---

### 30. `external_search`

Searches external encyclopedic knowledge, dictionaries, and legal archives.

**Parameters:**

| Name | Type | Required | Description |
|------|------|----------|-------------|
| `query` | string | Yes | Search query string |

**Example:** `{"query":"quantum entanglement"}` → `{"results":["Quantum entanglement is a phenomenon..."]}`

---

### 31. `kg_add_triplet`

Adds a knowledge triplet (subject, predicate, object) to the Qstar knowledge graph.

**Parameters:**

| Name | Type | Required | Description |
|------|------|----------|-------------|
| `subject` | string | Yes | Subject entity |
| `predicate` | string | Yes | Predicate/relationship |
| `object` | string | Yes | Object entity |

**Example:** `{"subject":"Quantum","predicate":"uses","object":"superposition"}` → `{"status":"added","triplets":1}`

---

### 32. `kg_export`

Exports the knowledge graph as a JSON array of triplets.

**Parameters:** None

**Example:** `{}` → `{"triplets":[{"subject":"...","predicate":"...","object":"..."},...]}`

---

## Data Analysis Tools (6)

### 33. `stats_compute`

Computes descriptive statistics (mean, median, min, max, std dev) for a numeric array.

**Parameters:**

| Name | Type | Required | Description |
|------|------|----------|-------------|
| `values` | array of numbers | Yes | Numeric values to analyze |

**Example:** `{"values":[1,2,3,4,5]}` → `{"mean":3,"median":3,"min":1,"max":5,"stddev":1.414214}`

---

### 34. `csv_parse`

Parses CSV text into a JSON object with headers and rows.

**Parameters:**

| Name | Type | Required | Description |
|------|------|----------|-------------|
| `data` | string | Yes | CSV text to parse |

**Example:** `{"data":"a,b\n1,2"}` → `{"headers":["a","b"],"rows":[["1","2"]]}`

---

### 35. `data_sort`

Sorts a numeric array in ascending or descending order.

**Parameters:**

| Name | Type | Required | Description |
|------|------|----------|-------------|
| `values` | array of numbers | Yes | Values to sort |
| `order` | string | No | Sort order: `asc` or `desc` (default: `asc`) |

**Example:** `{"values":[3,1,2]}` → `{"sorted":[1,2,3]}`

---

### 36. `data_filter`

Filters a numeric array by a condition (gt, lt, eq, gte, lte).

**Parameters:**

| Name | Type | Required | Description |
|------|------|----------|-------------|
| `values` | array of numbers | Yes | Values to filter |
| `op` | string | Yes | Comparison operator: `gt`, `lt`, `eq`, `gte`, `lte` |
| `threshold` | number | Yes | Threshold value |

**Example:** `{"values":[1,2,3,4,5],"op":"gt","threshold":2}` → `{"filtered":[3,4,5]}`

---

### 37. `histogram_generate`

Computes a histogram of a numeric array with configurable bins.

**Parameters:**

| Name | Type | Required | Description |
|------|------|----------|-------------|
| `values` | array of numbers | Yes | Values to bin |
| `bins` | integer | No | Number of bins (default: 10) |

**Example:** `{"values":[1,2,3,4,5],"bins":3}` → `{"bins":[{"min":1,"max":2.33,"count":2},...]}`

---

### 38. `correlation_compute`

Computes the Pearson correlation coefficient between two numeric arrays.

**Parameters:**

| Name | Type | Required | Description |
|------|------|----------|-------------|
| `values_a` | array of numbers | Yes | First array |
| `values_b` | array of numbers | Yes | Second array (same length) |

**Example:** `{"values_a":[1,2,3],"values_b":[2,4,6]}` → `{"pearson_r":1.000000,"n":3}`

---

## Geoview Tools (14)

### 39. `geo_distance`

Computes great-circle distance and bearing between two coordinates using the WGS84 ellipsoid.

**Parameters:**

| Name | Type | Required | Description |
|------|------|----------|-------------|
| `lat1` | number | Yes | Latitude of point 1 |
| `lon1` | number | Yes | Longitude of point 1 |
| `lat2` | number | Yes | Latitude of point 2 |
| `lon2` | number | Yes | Longitude of point 2 |

**Example:** `{"lat1":40.7,"lon1":-74.0,"lat2":51.5,"lon2":-0.1}` → `{"distance_m":5570134.22,"distance_km":5570.13,"bearing_deg":51.21,"cardinal":"NE"}`

---

### 40. `geo_convert`

Converts LLA (latitude, longitude, altitude) to ECEF (Earth-Centered, Earth-Fixed) and MGRS representations.

**Parameters:**

| Name | Type | Required | Description |
|------|------|----------|-------------|
| `lat` | number | Yes | Latitude |
| `lon` | number | Yes | Longitude |
| `alt` | number | No | Altitude in meters (default: 0) |

**Example:** `{"lat":40.7,"lon":-74.0}` → `{"ecef":{"x":1326543.12,"y":-4703834.56,"z":4286421.78},"mgrs":"18TWF8395907357"}`

---

### 41. `geo_mgrs`

Encodes a latitude/longitude pair to an MGRS (Military Grid Reference System) grid reference.

**Parameters:**

| Name | Type | Required | Description |
|------|------|----------|-------------|
| `lat` | number | Yes | Latitude |
| `lon` | number | Yes | Longitude |

**Example:** `{"lat":40.7128,"lon":-74.006}` → `{"mgrs":"18TWF8395907357","lat":40.712800,"lon":-74.006000}`

---

### 42. `geo_bearing`

Computes the bearing (azimuth) and cardinal direction from an origin point to a destination point.

**Parameters:**

| Name | Type | Required | Description |
|------|------|----------|-------------|
| `lat1` | number | Yes | Latitude of origin |
| `lon1` | number | Yes | Longitude of origin |
| `lat2` | number | Yes | Latitude of destination |
| `lon2` | number | Yes | Longitude of destination |

**Example:** `{"lat1":40.7,"lon1":-74.0,"lat2":51.5,"lon2":-0.1}` → `{"bearing_deg":51.21,"cardinal":"NE"}`

---

### 43. `geo_destination`

Computes the destination point given an origin, bearing, and distance using great-circle navigation.

**Parameters:**

| Name | Type | Required | Description |
|------|------|----------|-------------|
| `lat` | number | Yes | Origin latitude |
| `lon` | number | Yes | Origin longitude |
| `bearing` | number | Yes | Bearing in degrees |
| `distance` | number | Yes | Distance in meters |

**Example:** `{"lat":40.7,"lon":-74.0,"bearing":51.21,"distance":5570134}` → `{"lat":51.507400,"lon":-0.127800,"bearing":51.21,"distance_m":5570134.00}`

---

### 44. `globe_query`

Queries the globe for entities within a radius of a point, returning coordinate transforms and distance info.

**Parameters:**

| Name | Type | Required | Description |
|------|------|----------|-------------|
| `lat` | number | Yes | Center latitude |
| `lon` | number | Yes | Center longitude |
| `radius_km` | number | No | Search radius in km (default: 100) |
| `entity_type` | string | No | Entity type filter |

**Example:** `{"lat":40.7,"lon":-74.0,"radius_km":50}` → `{"entities":[...],"count":0}`

---

### 45. `track_flight`

Classifies an aircraft by callsign and computes dead-reckoned position.

**Parameters:**

| Name | Type | Required | Description |
|------|------|----------|-------------|
| `callsign` | string | Yes | Aircraft callsign |
| `lat` | number | Yes | Current latitude |
| `lon` | number | Yes | Current longitude |
| `altitude_m` | number | No | Altitude in meters |
| `velocity_mps` | number | No | Velocity in m/s |
| `heading_deg` | number | No | Heading in degrees |
| `dt_seconds` | number | No | Time delta in seconds |

**Example:** `{"callsign":"UAL123","lat":40.7,"lon":-74.0,"heading_deg":90,"dt_seconds":60}` → `{"type":"commercial","position":{...}}`

---

### 46. `track_vessel`

Classifies a vessel by AIS type code and computes dead-reckoned position.

**Parameters:**

| Name | Type | Required | Description |
|------|------|----------|-------------|
| `mmsi` | string | Yes | Vessel MMSI |
| `name` | string | No | Vessel name |
| `lat` | number | Yes | Current latitude |
| `lon` | number | Yes | Current longitude |
| `speed_knots` | number | No | Speed in knots |
| `course_deg` | number | No | Course in degrees |
| `type_code` | integer | No | AIS type code |
| `nav_status_code` | integer | No | AIS nav status code |
| `dt_hours` | number | No | Time delta in hours |

**Example:** `{"mmsi":"366123456","lat":40.7,"lon":-74.0,"speed_knots":12}` → `{"type":"cargo","position":{...}}`

---

### 47. `track_satellite`

Tracks a satellite by NORAD ID using TLE propagation.

**Parameters:**

| Name | Type | Required | Description |
|------|------|----------|-------------|
| `norad_id` | string | Yes | NORAD catalog ID |
| `name` | string | No | Satellite name |
| `tle_line1` | string | No | TLE line 1 |
| `tle_line2` | string | No | TLE line 2 |

**Example:** `{"norad_id":"25544"}` → `{"name":"ISS","position":{...}}`

---

### 48. `earthquake_query`

Queries earthquake data by magnitude and timeframe.

**Parameters:**

| Name | Type | Required | Description |
|------|------|----------|-------------|
| `min_magnitude` | number | No | Minimum magnitude (default: 4.5) |
| `geojson` | string | No | GeoJSON data |
| `timeframe` | string | No | Timeframe filter |

**Example:** `{"min_magnitude":5.0}` → `{"earthquakes":[...],"count":0}`

---

### 49. `cctv_query`

Queries CCTV camera registry within a field of view.

**Parameters:**

| Name | Type | Required | Description |
|------|------|----------|-------------|
| `lat` | number | Yes | Camera latitude |
| `lon` | number | Yes | Camera longitude |
| `heading_deg` | number | No | Camera heading |
| `fov_deg` | number | No | Field of view in degrees |
| `range_km` | number | No | Range in km |
| `target_lat` | number | No | Target latitude |
| `target_lon` | number | No | Target longitude |

**Example:** `{"lat":40.7,"lon":-74.0,"range_km":5}` → `{"cameras":[...],"count":0}`

---

### 50. `hud_control`

Controls the intelligence HUD (compass, coordinates, alerts).

**Parameters:**

| Name | Type | Required | Description |
|------|------|----------|-------------|
| `action` | string | Yes | Action: `show`, `hide`, `set` |
| `heading_deg` | number | No | Heading for compass |
| `pitch_deg` | number | No | Pitch angle |
| `lat` | number | No | Latitude for coordinates |
| `lon` | number | No | Longitude for coordinates |
| `alt_m` | number | No | Altitude in meters |
| `meters_per_pixel` | number | No | Scale bar meters/pixel |
| `entity_count` | integer | No | Entity count for alert |
| `message` | string | No | Alert message |

**Example:** `{"action":"show","heading_deg":90}` → `{"status":"ok","hud":{...}}`

---

### 51. `scene_play`

Plays a scene in the scene director.

**Parameters:**

| Name | Type | Required | Description |
|------|------|----------|-------------|
| `action` | string | Yes | Action: `play`, `pause`, `stop` |
| `lat` | number | No | Focus latitude |
| `lon` | number | No | Focus longitude |
| `priority` | integer | No | Scene priority |
| `duration_s` | number | No | Scene duration in seconds |
| `label` | string | No | Scene label |

**Example:** `{"action":"play","lat":40.7,"lon":-74.0}` → `{"status":"playing","scene":{...}}`

---

### 52. `annotation_add`

Adds an annotation (pin, route, measurement) to the map.

**Parameters:**

| Name | Type | Required | Description |
|------|------|----------|-------------|
| `type` | string | Yes | Annotation type: `pin`, `route`, `measurement` |
| `lat` | number | Yes | Latitude |
| `lon` | number | Yes | Longitude |
| `title` | string | No | Annotation title |
| `description` | string | No | Annotation description |
| `to_lat` | number | No | End latitude (route/measurement) |
| `to_lon` | number | No | End longitude (route/measurement) |

**Example:** `{"type":"pin","lat":40.7,"lon":-74.0,"title":"HQ"}` → `{"status":"added","annotation":{...}}`

---

## Vision Tools (6)

### 53. `face_detect`

Detects and filters face bounding boxes by confidence threshold.

**Parameters:**

| Name | Type | Required | Description |
|------|------|----------|-------------|
| `boxes` | array | Yes | Raw detection boxes |
| `img_width` | integer | Yes | Image width |
| `img_height` | integer | Yes | Image height |
| `threshold` | number | No | Confidence threshold (default: 0.5) |

**Example:** `{"boxes":[...],"img_width":640,"img_height":480}` → `{"faces":[...],"count":1}`

---

### 54. `face_recognize`

Computes cosine similarity between two face embeddings for recognition.

**Parameters:**

| Name | Type | Required | Description |
|------|------|----------|-------------|
| `embedding_a` | array | Yes | First embedding |
| `embedding_b` | array | Yes | Second embedding |

**Example:** `{"embedding_a":[...],"embedding_b":[...]}` → `{"similarity":0.95}`

---

### 55. `face_analyze`

Analyzes a face region: size ratio, aspect ratio, quality heuristics.

**Parameters:**

| Name | Type | Required | Description |
|------|------|----------|-------------|
| `x1` | number | Yes | Box left |
| `y1` | number | Yes | Box top |
| `x2` | number | Yes | Box right |
| `y2` | number | Yes | Box bottom |
| `img_width` | integer | Yes | Image width |
| `img_height` | integer | Yes | Image height |

**Example:** `{"x1":10,"y1":10,"x2":100,"y2":120,"img_width":640,"img_height":480}` → `{"analysis":{...}}`

---

### 56. `face_track`

Tracks faces across frames using IoU matching.

**Parameters:**

| Name | Type | Required | Description |
|------|------|----------|-------------|
| `prev_boxes` | array | Yes | Previous frame boxes |
| `curr_boxes` | array | Yes | Current frame boxes |
| `iou_threshold` | number | No | IoU threshold (default: 0.5) |

**Example:** `{"prev_boxes":[...],"curr_boxes":[...]}` → `{"tracks":[...]}`

---

### 57. `gaze_estimate`

Estimates gaze direction from eye and nose landmarks.

**Parameters:**

| Name | Type | Required | Description |
|------|------|----------|-------------|
| `left_eye_x` | number | Yes | Left eye X |
| `left_eye_y` | number | Yes | Left eye Y |
| `right_eye_x` | number | Yes | Right eye X |
| `right_eye_y` | number | Yes | Right eye Y |
| `nose_x` | number | Yes | Nose X |
| `nose_y` | number | Yes | Nose Y |

**Example:** `{"left_eye_x":100,"left_eye_y":100,"right_eye_x":200,"right_eye_y":100,"nose_x":150,"nose_y":150}` → `{"gaze":{...}}`

---

### 58. `emotion_detect`

Classifies emotion from detection scores.

**Parameters:**

| Name | Type | Required | Description |
|------|------|----------|-------------|
| `scores` | array | Yes | Emotion class scores |

**Example:** `{"scores":[0.1,0.8,0.05,0.05]}` → `{"emotion":"happy","confidence":0.8}`

---

## ToolRegistry API

```zig
// Initialize the tool registry
var reg = ToolRegistry.init(allocator);
defer reg.deinit();

// Attach knowledge graph and external DB
reg.attachKnowledgeGraph(&kg);
reg.attachExternalDb(&db);

// Execute a tool call
const call = ToolCall{
    .id = "call_1",
    .name = "calculate",
    .arguments_json = "{\"op\":\"add\",\"a\":40,\"b\":2}",
};
const result = try reg.execute(call);
defer allocator.free(result);

// Parse tool call markup from agent text
const parsed = ToolRegistry.parseToolCall(allocator, text);
```

## JsonValue Helper

The `JsonValue` struct provides lightweight JSON value extraction for tool argument parsing:

- `getString(key)` — Extract a string field
- `getNumber(key)` — Extract a float field
- `getInteger(key)` — Extract an integer field
- `getBool(key)` — Extract a boolean field

## Test Coverage

All 58 tools have dedicated tests in `src/tools.zig` (54 tests total) plus integration tests in `tests/tool_server_test.zig` (44 tool tests). Run with:

```bash
zig build tool-test
```

## CLI Usage

```bash
# Call a tool directly from the command line
qstar call calculate '{"op":"mul","a":7,"b":6}'
qstar call lattice_node '{"x":3,"y":0,"z":0}'
qstar call quantum_simulate '{"circuit":"bell","qubits":2}'
```
