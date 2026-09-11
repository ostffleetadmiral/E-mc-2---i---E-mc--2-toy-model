// License: CC BY-NC-SA 4.0

const fixed = @import("fixed_point.zig");

pub const phi = fixed.Q128.fromRaw(550588435450341336629110977315780544564);
pub const pi = fixed.Q128.fromRaw(1069028584064966747859680373161870783300);
pub const sqrt5 = fixed.Q128.fromRaw(790231711353346013421113761587364630568);

pub const c_m_per_s: u64 = 299792458;
pub const h_j_s: u64 = 662607015;
pub const hbar_j_s: u64 = 105457181;

pub const alpha_inverse_reference = fixed.Q128.fromRaw(46630934153325335303234647273662486708739);
pub const hydrogen_target_cm = fixed.Q128.fromRaw(7182020259407079994007285275016545289250);

pub const vacuum_impedance_raw: fixed.Raw = 1282243446409028258291782773997371546380;
pub const von_klitzing_raw: fixed.Raw = 87875057465066443643118870980678574515700000;
