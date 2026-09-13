# God's Eye View — Native Vision Geospatial Integration

## Overview

The God's Eye View is a comprehensive geospatial visualization and analysis system integrated directly into the Qstar-LLM binary. It provides real-time tracking of flights, vessels, satellites, earthquakes, traffic, and CCTV cameras on a 3D globe with HUD overlays, detection tracking, user annotations, and automated camera control.

All modules are pure Zig with zero external dependencies beyond the standard library.

## Architecture

### Phase 5: Geospatial Foundation (`src/geoview/geo_math.zig`)

Core geospatial mathematics:
- **WGS84 ellipsoid** — accurate Earth model with semi-major axis (6,378,137m) and flattening (1/298.257223563)
- **Coordinate conversions** — LLA ↔ ECEF, LLA ↔ ENU/NED, LLA ↔ MGRS
- **Great circle calculations** — distance, bearing, destination point
- **MGRS grid** — full Military Grid Reference System encoding/decoding with 100km grid squares
- **Spherical/hyperbolic geometry** — haversine, Vincenty approximation

### Phase 6: Live Data Feeds

Seven modules for real-time entity tracking:

| Module | Source | Entities |
|--------|--------|----------|
| `live_feeds.zig` | Internal | Feed manager, layer state, staleness tracking |
| `feed_flights.zig` | OpenSky Network | Aircraft positions, callsigns, altitude, velocity |
| `feed_vessels.zig` | AIS | Vessel positions, MMSI, navigation status, type |
| `feed_satellites.zig` | Celestrak TLE | Satellite positions via SGP4 propagation |
| `feed_earthquakes.zig` | USGS GeoJSON | Earthquake events, magnitude, depth, location |
| `feed_traffic.zig` | TomTom | Traffic flow, congestion levels, incidents |
| `feed_cctv.zig` | JSON config | Camera positions, viewshed polygons, status |

Each feed module includes:
- JSON parsing for API responses
- Dead-reckoning for position extrapolation
- Entity classification and filtering
- Comprehensive unit tests

### Phase 7: Overlays & HUD

Five modules for visual presentation:

| Module | Purpose |
|--------|---------|
| `hud.zig` | HUD renderer: compass, scale bar, coordinate readout, status panel, alerts, crosshair |
| `detection_overlay.zig` | Bounding box management, IoU tracking, confidence filtering, class-based styling |
| `annotation.zig` | User annotations: pins, routes, measurements, GeoJSON export |
| `scene_director.zig` | Automated camera control: flyTo, orbit, tracked, cockpit modes; storyboard playback |
| `styles.zig` | Visual themes: tactical green, amber, dark blue, high contrast, night vision; entity styles |

### Phase 8: Agent Integration

#### Tool Calling (`src/tools.zig`)

Five geoview tools registered in the tool calling engine:

1. **`geo_distance`** — Great-circle distance and bearing between two coordinates
2. **`geo_convert`** — LLA to ECEF and MGRS conversion
3. **`geo_mgrs`** — Lat/lon to MGRS grid reference encoding
4. **`geo_bearing`** — Bearing and cardinal direction between two points
5. **`geo_destination`** — Destination point from origin, bearing, and distance

#### API Endpoints (`src/server.zig`)

- `POST /api/geoview` — Execute geoview tool with JSON arguments
- `GET /api/geoview/tools` — List available geoview tools

#### Voice Commands (`src/geoview/voice_command.zig`)

Natural language command parsing for hands-free operation:
- "Fly to 40.7 -74.0" → fly_to action with coordinates
- "Show flights layer" → toggle_layer action
- "Focus on entity 42" → focus_entity action
- "Measure distance to 40.0 -74.0" → measure_distance action
- "Add pin at 40.7 -74.0 New York" → add_pin action
- "Switch to cockpit view" → set_camera_mode action
- "Clear all annotations" → clear_annotations action

#### CLI (`src/main.zig`)

```bash
qstar geoview distance <lat1> <lon1> <lat2> <lon2>  # Distance + bearing
qstar geoview convert <lat> <lon> [alt]               # LLA → ECEF + MGRS
qstar geoview mgrs <lat> <lon>                        # LLA → MGRS
qstar geoview bearing <lat1> <lon1> <lat2> <lon2>     # Bearing + cardinal
qstar geoview destination <lat> <lon> <brng> <dist>   # Destination point
```

## Build Integration

All geoview modules are wired into `build.zig`:
- Module definitions with proper dependency chains
- Test specs for all 14 modules (geo_math, globe_render, camera, live_feeds, 6 feed modules, 5 overlay/HUD modules, voice_command)
- `geo_math` import added to `tools_mod`, `cli_tools_mod`, and WASM tools module
- CLI executable includes `geo_math` for geoview subcommands

## Test Coverage

Every module includes comprehensive unit tests:
- Geospatial math: coordinate conversion round-trips, MGRS encoding, distance/bearing accuracy
- Feed parsing: JSON extraction, entity classification, dead-reckoning
- HUD: compass directions, scale bar calculation, element visibility
- Detection overlay: IoU calculation, tracking, class styling
- Annotation: pin/route management, GeoJSON export
- Scene director: focus queuing, storyboard playback
- Styles: theme palettes, color conversion
- Voice commands: all action types, case insensitivity, coordinate extraction
- Tools: geo_distance, geo_convert, geo_mgrs, geo_bearing, geo_destination

## Verification

All build targets pass with zero regressions:
- `zig build test` — All unit tests pass
- `zig build tool-test` — Tool calling and server integration tests pass
- `zig build manual` — Manual integration tests pass
- `zig build samc` — SAMC prototype validation passes
- `zig build audit` — Agent dual-mode audit passes
- `zig build wasm` — WASM module builds successfully
- `zig build` — Main binary builds successfully
