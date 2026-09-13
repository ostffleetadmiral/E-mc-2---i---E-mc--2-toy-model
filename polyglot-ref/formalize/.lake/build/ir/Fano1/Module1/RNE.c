// Lean compiler output
// Module: Fano1.Module1.RNE
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
lean_object* lean_nat_to_int(lean_object*);
lean_object* lean_int_ediv(lean_object*, lean_object*);
lean_object* lean_int_emod(lean_object*, lean_object*);
lean_object* lean_int_mul(lean_object*, lean_object*);
uint8_t lean_int_dec_lt(lean_object*, lean_object*);
uint8_t lean_int_dec_eq(lean_object*, lean_object*);
lean_object* lean_int_add(lean_object*, lean_object*);
extern lean_object* lp_fano1_Fano1_Module1_SCALE;
static lean_once_cell_t lp_fano1_Fano1_Module1_rne___redArg___closed__0_once = LEAN_ONCE_CELL_INITIALIZER;
static lean_object* lp_fano1_Fano1_Module1_rne___redArg___closed__0;
static lean_once_cell_t lp_fano1_Fano1_Module1_rne___redArg___closed__1_once = LEAN_ONCE_CELL_INITIALIZER;
static lean_object* lp_fano1_Fano1_Module1_rne___redArg___closed__1;
static lean_once_cell_t lp_fano1_Fano1_Module1_rne___redArg___closed__2_once = LEAN_ONCE_CELL_INITIALIZER;
static lean_object* lp_fano1_Fano1_Module1_rne___redArg___closed__2;
LEAN_EXPORT lean_object* lp_fano1_Fano1_Module1_rne___redArg(lean_object*, lean_object*);
LEAN_EXPORT lean_object* lp_fano1_Fano1_Module1_rne___redArg___boxed(lean_object*, lean_object*);
LEAN_EXPORT lean_object* lp_fano1_Fano1_Module1_rne(lean_object*, lean_object*, lean_object*);
LEAN_EXPORT lean_object* lp_fano1_Fano1_Module1_rne___boxed(lean_object*, lean_object*, lean_object*);
LEAN_EXPORT lean_object* lp_fano1_Fano1_Module1_F128_mul(lean_object*, lean_object*);
LEAN_EXPORT lean_object* lp_fano1_Fano1_Module1_F128_mul___boxed(lean_object*, lean_object*);
static lean_object* _init_lp_fano1_Fano1_Module1_rne___redArg___closed__0(void){
_start:
{
lean_object* v___x_1_; lean_object* v___x_2_; 
v___x_1_ = lean_unsigned_to_nat(2u);
v___x_2_ = lean_nat_to_int(v___x_1_);
return v___x_2_;
}
}
static lean_object* _init_lp_fano1_Fano1_Module1_rne___redArg___closed__1(void){
_start:
{
lean_object* v___x_3_; lean_object* v___x_4_; 
v___x_3_ = lean_unsigned_to_nat(0u);
v___x_4_ = lean_nat_to_int(v___x_3_);
return v___x_4_;
}
}
static lean_object* _init_lp_fano1_Fano1_Module1_rne___redArg___closed__2(void){
_start:
{
lean_object* v___x_5_; lean_object* v___x_6_; 
v___x_5_ = lean_unsigned_to_nat(1u);
v___x_6_ = lean_nat_to_int(v___x_5_);
return v___x_6_;
}
}
LEAN_EXPORT lean_object* lp_fano1_Fano1_Module1_rne___redArg(lean_object* v_num_7_, lean_object* v_denom_8_){
_start:
{
lean_object* v_q_9_; lean_object* v_r_10_; lean_object* v___x_11_; lean_object* v___x_12_; uint8_t v___x_13_; 
v_q_9_ = lean_int_ediv(v_num_7_, v_denom_8_);
v_r_10_ = lean_int_emod(v_num_7_, v_denom_8_);
v___x_11_ = lean_obj_once(&lp_fano1_Fano1_Module1_rne___redArg___closed__0, &lp_fano1_Fano1_Module1_rne___redArg___closed__0_once, _init_lp_fano1_Fano1_Module1_rne___redArg___closed__0);
v___x_12_ = lean_int_mul(v___x_11_, v_r_10_);
lean_dec(v_r_10_);
v___x_13_ = lean_int_dec_lt(v___x_12_, v_denom_8_);
if (v___x_13_ == 0)
{
uint8_t v___x_14_; 
v___x_14_ = lean_int_dec_lt(v_denom_8_, v___x_12_);
lean_dec(v___x_12_);
if (v___x_14_ == 0)
{
lean_object* v___x_15_; lean_object* v___x_16_; uint8_t v___x_17_; 
v___x_15_ = lean_int_emod(v_q_9_, v___x_11_);
v___x_16_ = lean_obj_once(&lp_fano1_Fano1_Module1_rne___redArg___closed__1, &lp_fano1_Fano1_Module1_rne___redArg___closed__1_once, _init_lp_fano1_Fano1_Module1_rne___redArg___closed__1);
v___x_17_ = lean_int_dec_eq(v___x_15_, v___x_16_);
lean_dec(v___x_15_);
if (v___x_17_ == 0)
{
lean_object* v___x_18_; lean_object* v___x_19_; 
v___x_18_ = lean_obj_once(&lp_fano1_Fano1_Module1_rne___redArg___closed__2, &lp_fano1_Fano1_Module1_rne___redArg___closed__2_once, _init_lp_fano1_Fano1_Module1_rne___redArg___closed__2);
v___x_19_ = lean_int_add(v_q_9_, v___x_18_);
lean_dec(v_q_9_);
return v___x_19_;
}
else
{
return v_q_9_;
}
}
else
{
lean_object* v___x_20_; lean_object* v___x_21_; 
v___x_20_ = lean_obj_once(&lp_fano1_Fano1_Module1_rne___redArg___closed__2, &lp_fano1_Fano1_Module1_rne___redArg___closed__2_once, _init_lp_fano1_Fano1_Module1_rne___redArg___closed__2);
v___x_21_ = lean_int_add(v_q_9_, v___x_20_);
lean_dec(v_q_9_);
return v___x_21_;
}
}
else
{
lean_dec(v___x_12_);
return v_q_9_;
}
}
}
LEAN_EXPORT lean_object* lp_fano1_Fano1_Module1_rne___redArg___boxed(lean_object* v_num_22_, lean_object* v_denom_23_){
_start:
{
lean_object* v_res_24_; 
v_res_24_ = lp_fano1_Fano1_Module1_rne___redArg(v_num_22_, v_denom_23_);
lean_dec(v_denom_23_);
lean_dec(v_num_22_);
return v_res_24_;
}
}
LEAN_EXPORT lean_object* lp_fano1_Fano1_Module1_rne(lean_object* v_num_25_, lean_object* v_denom_26_, lean_object* v_denom__pos_27_){
_start:
{
lean_object* v___x_28_; 
v___x_28_ = lp_fano1_Fano1_Module1_rne___redArg(v_num_25_, v_denom_26_);
return v___x_28_;
}
}
LEAN_EXPORT lean_object* lp_fano1_Fano1_Module1_rne___boxed(lean_object* v_num_29_, lean_object* v_denom_30_, lean_object* v_denom__pos_31_){
_start:
{
lean_object* v_res_32_; 
v_res_32_ = lp_fano1_Fano1_Module1_rne(v_num_29_, v_denom_30_, v_denom__pos_31_);
lean_dec(v_denom_30_);
lean_dec(v_num_29_);
return v_res_32_;
}
}
LEAN_EXPORT lean_object* lp_fano1_Fano1_Module1_F128_mul(lean_object* v_x_33_, lean_object* v_y_34_){
_start:
{
lean_object* v___x_35_; lean_object* v___x_36_; lean_object* v___x_37_; 
v___x_35_ = lean_int_mul(v_x_33_, v_y_34_);
v___x_36_ = lp_fano1_Fano1_Module1_SCALE;
v___x_37_ = lp_fano1_Fano1_Module1_rne___redArg(v___x_35_, v___x_36_);
lean_dec(v___x_35_);
return v___x_37_;
}
}
LEAN_EXPORT lean_object* lp_fano1_Fano1_Module1_F128_mul___boxed(lean_object* v_x_38_, lean_object* v_y_39_){
_start:
{
lean_object* v_res_40_; 
v_res_40_ = lp_fano1_Fano1_Module1_F128_mul(v_x_38_, v_y_39_);
lean_dec(v_y_39_);
lean_dec(v_x_38_);
return v_res_40_;
}
}
lean_object* initialize_Init(uint8_t builtin);
lean_object* initialize_Init(uint8_t builtin);
lean_object* initialize_fano1_Fano1_Module1_FixedPoint(uint8_t builtin);
static bool _G_initialized = false;
LEAN_EXPORT lean_object* initialize_fano1_Fano1_Module1_RNE(uint8_t builtin) {
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
return lean_io_result_mk_ok(lean_box(0));
}
#ifdef __cplusplus
}
#endif
