// Lean compiler output
// Module: Fano1.Module5.RootProjection
// Imports: public import Init public meta import Init public import Fano1.Module1.FixedPoint
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
uint8_t lean_nat_dec_eq(lean_object*, lean_object*);
extern lean_object* lp_fano1_Fano1_Module1_F128_zero;
extern lean_object* lp_fano1_Fano1_Module1_SCALE;
LEAN_EXPORT lean_object* lp_fano1_Fano1_Module5_MAT__DIM;
LEAN_EXPORT lean_object* lp_fano1_Fano1_Module5_E8__ROOTS;
LEAN_EXPORT lean_object* lp_fano1_Fano1_Module5_E8x8__ROOTS;
LEAN_EXPORT lean_object* lp_fano1_Fano1_Module5_E8x8__GENERATORS;
LEAN_EXPORT lean_object* lp_fano1_Fano1_Module5_matrix__unit(lean_object*, lean_object*, lean_object*, lean_object*);
LEAN_EXPORT lean_object* lp_fano1_Fano1_Module5_matrix__unit___boxed(lean_object*, lean_object*, lean_object*, lean_object*);
static lean_object* _init_lp_fano1_Fano1_Module5_MAT__DIM(void){
_start:
{
lean_object* v___x_1_; 
v___x_1_ = lean_unsigned_to_nat(256u);
return v___x_1_;
}
}
static lean_object* _init_lp_fano1_Fano1_Module5_E8__ROOTS(void){
_start:
{
lean_object* v___x_2_; 
v___x_2_ = lean_unsigned_to_nat(240u);
return v___x_2_;
}
}
static lean_object* _init_lp_fano1_Fano1_Module5_E8x8__ROOTS(void){
_start:
{
lean_object* v___x_3_; 
v___x_3_ = lean_unsigned_to_nat(480u);
return v___x_3_;
}
}
static lean_object* _init_lp_fano1_Fano1_Module5_E8x8__GENERATORS(void){
_start:
{
lean_object* v___x_4_; 
v___x_4_ = lean_unsigned_to_nat(496u);
return v___x_4_;
}
}
LEAN_EXPORT lean_object* lp_fano1_Fano1_Module5_matrix__unit(lean_object* v_a_5_, lean_object* v_b_6_, lean_object* v_i_7_, lean_object* v_j_8_){
_start:
{
uint8_t v___x_9_; 
v___x_9_ = lean_nat_dec_eq(v_i_7_, v_a_5_);
if (v___x_9_ == 0)
{
lean_object* v___x_10_; 
v___x_10_ = lp_fano1_Fano1_Module1_F128_zero;
return v___x_10_;
}
else
{
uint8_t v___x_11_; 
v___x_11_ = lean_nat_dec_eq(v_j_8_, v_b_6_);
if (v___x_11_ == 0)
{
lean_object* v___x_12_; 
v___x_12_ = lp_fano1_Fano1_Module1_F128_zero;
return v___x_12_;
}
else
{
lean_object* v___x_13_; 
v___x_13_ = lp_fano1_Fano1_Module1_SCALE;
return v___x_13_;
}
}
}
}
LEAN_EXPORT lean_object* lp_fano1_Fano1_Module5_matrix__unit___boxed(lean_object* v_a_14_, lean_object* v_b_15_, lean_object* v_i_16_, lean_object* v_j_17_){
_start:
{
lean_object* v_res_18_; 
v_res_18_ = lp_fano1_Fano1_Module5_matrix__unit(v_a_14_, v_b_15_, v_i_16_, v_j_17_);
lean_dec(v_j_17_);
lean_dec(v_i_16_);
lean_dec(v_b_15_);
lean_dec(v_a_14_);
return v_res_18_;
}
}
lean_object* initialize_Init(uint8_t builtin);
lean_object* initialize_Init(uint8_t builtin);
lean_object* initialize_fano1_Fano1_Module1_FixedPoint(uint8_t builtin);
static bool _G_initialized = false;
LEAN_EXPORT lean_object* initialize_fano1_Fano1_Module5_RootProjection(uint8_t builtin) {
lean_object * res;
if (_G_initialized) return lean_io_result_mk_ok(lean_box(0));
_G_initialized = true;
res = initialize_Init(builtin);
if (lean_io_result_is_error(res)) return res;
lean_dec_ref(res);
res = initialize_Init(builtin);
if (lean_io_result_is_error(res)) return res;
lean_dec_ref(res);
res = initialize_fano1_Fano1_Module1_FixedPoint(builtin);
if (lean_io_result_is_error(res)) return res;
lean_dec_ref(res);
lp_fano1_Fano1_Module5_MAT__DIM = _init_lp_fano1_Fano1_Module5_MAT__DIM();
lean_mark_persistent(lp_fano1_Fano1_Module5_MAT__DIM);
lp_fano1_Fano1_Module5_E8__ROOTS = _init_lp_fano1_Fano1_Module5_E8__ROOTS();
lean_mark_persistent(lp_fano1_Fano1_Module5_E8__ROOTS);
lp_fano1_Fano1_Module5_E8x8__ROOTS = _init_lp_fano1_Fano1_Module5_E8x8__ROOTS();
lean_mark_persistent(lp_fano1_Fano1_Module5_E8x8__ROOTS);
lp_fano1_Fano1_Module5_E8x8__GENERATORS = _init_lp_fano1_Fano1_Module5_E8x8__GENERATORS();
lean_mark_persistent(lp_fano1_Fano1_Module5_E8x8__GENERATORS);
return lean_io_result_mk_ok(lean_box(0));
}
#ifdef __cplusplus
}
#endif
