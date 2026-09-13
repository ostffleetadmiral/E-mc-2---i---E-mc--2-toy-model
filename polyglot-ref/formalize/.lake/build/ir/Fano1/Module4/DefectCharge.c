// Lean compiler output
// Module: Fano1.Module4.DefectCharge
// Imports: public import Init public meta import Init public import Fano1.Module1.FixedPoint public import Fano1.Module3.Folding
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
lean_object* lean_nat_mul(lean_object*, lean_object*);
lean_object* lean_nat_add(lean_object*, lean_object*);
lean_object* lean_nat_pow(lean_object*, lean_object*);
lean_object* lean_nat_sub(lean_object*, lean_object*);
LEAN_EXPORT lean_object* lp_fano1_Fano1_Module4_K__PARAM;
LEAN_EXPORT lean_object* lp_fano1_Fano1_Module4_N__ODD;
LEAN_EXPORT lean_object* lp_fano1_Fano1_Module4_N__INNER;
LEAN_EXPORT lean_object* lp_fano1_Fano1_Module4_boundary__size(lean_object*);
LEAN_EXPORT lean_object* lp_fano1_Fano1_Module4_boundary__size___boxed(lean_object*);
LEAN_EXPORT lean_object* lp_fano1_Fano1_Module4_winding__number(lean_object*);
LEAN_EXPORT lean_object* lp_fano1_Fano1_Module4_winding__number___boxed(lean_object*);
static lean_object* _init_lp_fano1_Fano1_Module4_K__PARAM(void){
_start:
{
lean_object* v___x_1_; 
v___x_1_ = lean_unsigned_to_nat(256u);
return v___x_1_;
}
}
static lean_object* _init_lp_fano1_Fano1_Module4_N__ODD(void){
_start:
{
lean_object* v___x_2_; 
v___x_2_ = lean_unsigned_to_nat(513u);
return v___x_2_;
}
}
static lean_object* _init_lp_fano1_Fano1_Module4_N__INNER(void){
_start:
{
lean_object* v___x_3_; 
v___x_3_ = lean_unsigned_to_nat(512u);
return v___x_3_;
}
}
LEAN_EXPORT lean_object* lp_fano1_Fano1_Module4_boundary__size(lean_object* v_k_4_){
_start:
{
lean_object* v___x_5_; lean_object* v___x_6_; lean_object* v___x_7_; lean_object* v___x_8_; lean_object* v___x_9_; lean_object* v___x_10_; lean_object* v___x_11_; lean_object* v___x_12_; 
v___x_5_ = lean_unsigned_to_nat(2u);
v___x_6_ = lean_nat_mul(v___x_5_, v_k_4_);
v___x_7_ = lean_unsigned_to_nat(1u);
v___x_8_ = lean_nat_add(v___x_6_, v___x_7_);
v___x_9_ = lean_unsigned_to_nat(3u);
v___x_10_ = lean_nat_pow(v___x_8_, v___x_9_);
lean_dec(v___x_8_);
v___x_11_ = lean_nat_pow(v___x_6_, v___x_9_);
lean_dec(v___x_6_);
v___x_12_ = lean_nat_sub(v___x_10_, v___x_11_);
lean_dec(v___x_11_);
lean_dec(v___x_10_);
return v___x_12_;
}
}
LEAN_EXPORT lean_object* lp_fano1_Fano1_Module4_boundary__size___boxed(lean_object* v_k_13_){
_start:
{
lean_object* v_res_14_; 
v_res_14_ = lp_fano1_Fano1_Module4_boundary__size(v_k_13_);
lean_dec(v_k_13_);
return v_res_14_;
}
}
LEAN_EXPORT lean_object* lp_fano1_Fano1_Module4_winding__number(lean_object* v_A_15_){
_start:
{
lean_inc(v_A_15_);
return v_A_15_;
}
}
LEAN_EXPORT lean_object* lp_fano1_Fano1_Module4_winding__number___boxed(lean_object* v_A_16_){
_start:
{
lean_object* v_res_17_; 
v_res_17_ = lp_fano1_Fano1_Module4_winding__number(v_A_16_);
lean_dec(v_A_16_);
return v_res_17_;
}
}
lean_object* initialize_Init(uint8_t builtin);
lean_object* initialize_Init(uint8_t builtin);
lean_object* initialize_fano1_Fano1_Module1_FixedPoint(uint8_t builtin);
lean_object* initialize_fano1_Fano1_Module3_Folding(uint8_t builtin);
static bool _G_initialized = false;
LEAN_EXPORT lean_object* initialize_fano1_Fano1_Module4_DefectCharge(uint8_t builtin) {
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
res = initialize_fano1_Fano1_Module3_Folding(builtin);
if (lean_io_result_is_error(res)) return res;
lean_dec_ref(res);
lp_fano1_Fano1_Module4_K__PARAM = _init_lp_fano1_Fano1_Module4_K__PARAM();
lean_mark_persistent(lp_fano1_Fano1_Module4_K__PARAM);
lp_fano1_Fano1_Module4_N__ODD = _init_lp_fano1_Fano1_Module4_N__ODD();
lean_mark_persistent(lp_fano1_Fano1_Module4_N__ODD);
lp_fano1_Fano1_Module4_N__INNER = _init_lp_fano1_Fano1_Module4_N__INNER();
lean_mark_persistent(lp_fano1_Fano1_Module4_N__INNER);
return lean_io_result_mk_ok(lean_box(0));
}
#ifdef __cplusplus
}
#endif
