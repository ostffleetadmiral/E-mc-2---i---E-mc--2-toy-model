// Lean compiler output
// Module: Fano1.Module4.PhaseLock
// Imports: public import Init public meta import Init public import Fano1.Module4.DefectCharge
#include <lean/lean.h>
#if defined(__clang__)
#pragma clang diagnostic ignored "-Wunused-parameter"
#pragma clang diagnostic ignored "-Wunused-label"
#elif defined(__GNUC__) && !defined(__CLANG__)
#pragma GCC diagnostic ignored "-Wunused-parameter"
#pragma GCC diagnostic ignored "-Wunused-label"
#pragma GCC diagnostic ignored "-Wunused-but-set-variable"
#endif
#ifdef __cplusplus
extern "C" {
#endif
lean_object* lean_int_sub(lean_object*, lean_object*);
lean_object* lean_int_mul(lean_object*, lean_object*);
LEAN_EXPORT lean_object* lp_fano1_Fano1_Module4_lyapunov(lean_object*, lean_object*);
LEAN_EXPORT lean_object* lp_fano1_Fano1_Module4_lyapunov___boxed(lean_object*, lean_object*);
LEAN_EXPORT lean_object* lp_fano1_Fano1_Module4_lyapunov(lean_object* v_00_u03c6_1_, lean_object* v_00_u03c6_u2080_2_){
_start:
{
lean_object* v___x_3_; lean_object* v___x_4_; 
v___x_3_ = lean_int_sub(v_00_u03c6_1_, v_00_u03c6_u2080_2_);
v___x_4_ = lean_int_mul(v___x_3_, v___x_3_);
lean_dec(v___x_3_);
return v___x_4_;
}
}
LEAN_EXPORT lean_object* lp_fano1_Fano1_Module4_lyapunov___boxed(lean_object* v_00_u03c6_5_, lean_object* v_00_u03c6_u2080_6_){
_start:
{
lean_object* v_res_7_; 
v_res_7_ = lp_fano1_Fano1_Module4_lyapunov(v_00_u03c6_5_, v_00_u03c6_u2080_6_);
lean_dec(v_00_u03c6_u2080_6_);
lean_dec(v_00_u03c6_5_);
return v_res_7_;
}
}
lean_object* initialize_Init(uint8_t builtin);
lean_object* initialize_Init(uint8_t builtin);
lean_object* initialize_fano1_Fano1_Module4_DefectCharge(uint8_t builtin);
static bool _G_initialized = false;
LEAN_EXPORT lean_object* initialize_fano1_Fano1_Module4_PhaseLock(uint8_t builtin) {
lean_object * res;
if (_G_initialized) return lean_io_result_mk_ok(lean_box(0));
_G_initialized = true;
res = initialize_Init(builtin);
if (lean_io_result_is_error(res)) return res;
lean_dec_ref(res);
res = initialize_Init(builtin);
if (lean_io_result_is_error(res)) return res;
lean_dec_ref(res);
res = initialize_fano1_Fano1_Module4_DefectCharge(builtin);
if (lean_io_result_is_error(res)) return res;
lean_dec_ref(res);
return lean_io_result_mk_ok(lean_box(0));
}
#ifdef __cplusplus
}
#endif
