// Lean compiler output
// Module: Fano1.Module1.FixedPoint
// Imports: public import Init public meta import Init
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
lean_object* lean_int_neg(lean_object*);
lean_object* lean_int_sub(lean_object*, lean_object*);
lean_object* lean_nat_to_int(lean_object*);
lean_object* l_Int_pow(lean_object*, lean_object*);
uint8_t lean_int_dec_eq(lean_object*, lean_object*);
lean_object* lean_int_add(lean_object*, lean_object*);
static lean_once_cell_t lp_fano1_Fano1_Module1_SCALE___closed__0_once = LEAN_ONCE_CELL_INITIALIZER;
static lean_object* lp_fano1_Fano1_Module1_SCALE___closed__0;
static lean_once_cell_t lp_fano1_Fano1_Module1_SCALE___closed__1_once = LEAN_ONCE_CELL_INITIALIZER;
static lean_object* lp_fano1_Fano1_Module1_SCALE___closed__1;
LEAN_EXPORT lean_object* lp_fano1_Fano1_Module1_SCALE;
LEAN_EXPORT lean_object* lp_fano1_Fano1_Module1_F128_fromMantissa(lean_object*);
LEAN_EXPORT lean_object* lp_fano1_Fano1_Module1_F128_fromMantissa___boxed(lean_object*);
static lean_once_cell_t lp_fano1_Fano1_Module1_F128_zero___closed__0_once = LEAN_ONCE_CELL_INITIALIZER;
static lean_object* lp_fano1_Fano1_Module1_F128_zero___closed__0;
LEAN_EXPORT lean_object* lp_fano1_Fano1_Module1_F128_zero;
LEAN_EXPORT lean_object* lp_fano1_Fano1_Module1_F128_one;
LEAN_EXPORT lean_object* lp_fano1_Fano1_Module1_F128_add(lean_object*, lean_object*);
LEAN_EXPORT lean_object* lp_fano1_Fano1_Module1_F128_add___boxed(lean_object*, lean_object*);
LEAN_EXPORT lean_object* lp_fano1_Fano1_Module1_F128_sub(lean_object*, lean_object*);
LEAN_EXPORT lean_object* lp_fano1_Fano1_Module1_F128_sub___boxed(lean_object*, lean_object*);
LEAN_EXPORT lean_object* lp_fano1_Fano1_Module1_F128_neg(lean_object*);
LEAN_EXPORT lean_object* lp_fano1_Fano1_Module1_F128_neg___boxed(lean_object*);
LEAN_EXPORT uint8_t lp_fano1_Fano1_Module1_instDecidableEqF128(lean_object*, lean_object*);
LEAN_EXPORT lean_object* lp_fano1_Fano1_Module1_instDecidableEqF128___boxed(lean_object*, lean_object*);
static lean_object* _init_lp_fano1_Fano1_Module1_SCALE___closed__0(void){
_start:
{
lean_object* v___x_1_; lean_object* v___x_2_; 
v___x_1_ = lean_unsigned_to_nat(2u);
v___x_2_ = lean_nat_to_int(v___x_1_);
return v___x_2_;
}
}
static lean_object* _init_lp_fano1_Fano1_Module1_SCALE___closed__1(void){
_start:
{
lean_object* v___x_3_; lean_object* v___x_4_; lean_object* v___x_5_; 
v___x_3_ = lean_unsigned_to_nat(128u);
v___x_4_ = lean_obj_once(&lp_fano1_Fano1_Module1_SCALE___closed__0, &lp_fano1_Fano1_Module1_SCALE___closed__0_once, _init_lp_fano1_Fano1_Module1_SCALE___closed__0);
v___x_5_ = l_Int_pow(v___x_4_, v___x_3_);
return v___x_5_;
}
}
static lean_object* _init_lp_fano1_Fano1_Module1_SCALE(void){
_start:
{
lean_object* v___x_6_; 
v___x_6_ = lean_obj_once(&lp_fano1_Fano1_Module1_SCALE___closed__1, &lp_fano1_Fano1_Module1_SCALE___closed__1_once, _init_lp_fano1_Fano1_Module1_SCALE___closed__1);
return v___x_6_;
}
}
LEAN_EXPORT lean_object* lp_fano1_Fano1_Module1_F128_fromMantissa(lean_object* v_m_7_){
_start:
{
lean_inc(v_m_7_);
return v_m_7_;
}
}
LEAN_EXPORT lean_object* lp_fano1_Fano1_Module1_F128_fromMantissa___boxed(lean_object* v_m_8_){
_start:
{
lean_object* v_res_9_; 
v_res_9_ = lp_fano1_Fano1_Module1_F128_fromMantissa(v_m_8_);
lean_dec(v_m_8_);
return v_res_9_;
}
}
static lean_object* _init_lp_fano1_Fano1_Module1_F128_zero___closed__0(void){
_start:
{
lean_object* v___x_10_; lean_object* v___x_11_; 
v___x_10_ = lean_unsigned_to_nat(0u);
v___x_11_ = lean_nat_to_int(v___x_10_);
return v___x_11_;
}
}
static lean_object* _init_lp_fano1_Fano1_Module1_F128_zero(void){
_start:
{
lean_object* v___x_12_; 
v___x_12_ = lean_obj_once(&lp_fano1_Fano1_Module1_F128_zero___closed__0, &lp_fano1_Fano1_Module1_F128_zero___closed__0_once, _init_lp_fano1_Fano1_Module1_F128_zero___closed__0);
return v___x_12_;
}
}
static lean_object* _init_lp_fano1_Fano1_Module1_F128_one(void){
_start:
{
lean_object* v___x_13_; 
v___x_13_ = lp_fano1_Fano1_Module1_SCALE;
return v___x_13_;
}
}
LEAN_EXPORT lean_object* lp_fano1_Fano1_Module1_F128_add(lean_object* v_x_14_, lean_object* v_y_15_){
_start:
{
lean_object* v___x_16_; 
v___x_16_ = lean_int_add(v_x_14_, v_y_15_);
return v___x_16_;
}
}
LEAN_EXPORT lean_object* lp_fano1_Fano1_Module1_F128_add___boxed(lean_object* v_x_17_, lean_object* v_y_18_){
_start:
{
lean_object* v_res_19_; 
v_res_19_ = lp_fano1_Fano1_Module1_F128_add(v_x_17_, v_y_18_);
lean_dec(v_y_18_);
lean_dec(v_x_17_);
return v_res_19_;
}
}
LEAN_EXPORT lean_object* lp_fano1_Fano1_Module1_F128_sub(lean_object* v_x_20_, lean_object* v_y_21_){
_start:
{
lean_object* v___x_22_; 
v___x_22_ = lean_int_sub(v_x_20_, v_y_21_);
return v___x_22_;
}
}
LEAN_EXPORT lean_object* lp_fano1_Fano1_Module1_F128_sub___boxed(lean_object* v_x_23_, lean_object* v_y_24_){
_start:
{
lean_object* v_res_25_; 
v_res_25_ = lp_fano1_Fano1_Module1_F128_sub(v_x_23_, v_y_24_);
lean_dec(v_y_24_);
lean_dec(v_x_23_);
return v_res_25_;
}
}
LEAN_EXPORT lean_object* lp_fano1_Fano1_Module1_F128_neg(lean_object* v_x_26_){
_start:
{
lean_object* v___x_27_; 
v___x_27_ = lean_int_neg(v_x_26_);
return v___x_27_;
}
}
LEAN_EXPORT lean_object* lp_fano1_Fano1_Module1_F128_neg___boxed(lean_object* v_x_28_){
_start:
{
lean_object* v_res_29_; 
v_res_29_ = lp_fano1_Fano1_Module1_F128_neg(v_x_28_);
lean_dec(v_x_28_);
return v_res_29_;
}
}
LEAN_EXPORT uint8_t lp_fano1_Fano1_Module1_instDecidableEqF128(lean_object* v_x_30_, lean_object* v_y_31_){
_start:
{
uint8_t v___x_32_; 
v___x_32_ = lean_int_dec_eq(v_x_30_, v_y_31_);
return v___x_32_;
}
}
LEAN_EXPORT lean_object* lp_fano1_Fano1_Module1_instDecidableEqF128___boxed(lean_object* v_x_33_, lean_object* v_y_34_){
_start:
{
uint8_t v_res_35_; lean_object* v_r_36_; 
v_res_35_ = lp_fano1_Fano1_Module1_instDecidableEqF128(v_x_33_, v_y_34_);
lean_dec(v_y_34_);
lean_dec(v_x_33_);
v_r_36_ = lean_box(v_res_35_);
return v_r_36_;
}
}
lean_object* initialize_Init(uint8_t builtin);
lean_object* initialize_Init(uint8_t builtin);
static bool _G_initialized = false;
LEAN_EXPORT lean_object* initialize_fano1_Fano1_Module1_FixedPoint(uint8_t builtin) {
lean_object * res;
if (_G_initialized) return lean_io_result_mk_ok(lean_box(0));
_G_initialized = true;
res = initialize_Init(builtin);
if (lean_io_result_is_error(res)) return res;
lean_dec_ref(res);
res = initialize_Init(builtin);
if (lean_io_result_is_error(res)) return res;
lean_dec_ref(res);
lp_fano1_Fano1_Module1_SCALE = _init_lp_fano1_Fano1_Module1_SCALE();
lean_mark_persistent(lp_fano1_Fano1_Module1_SCALE);
lp_fano1_Fano1_Module1_F128_zero = _init_lp_fano1_Fano1_Module1_F128_zero();
lean_mark_persistent(lp_fano1_Fano1_Module1_F128_zero);
lp_fano1_Fano1_Module1_F128_one = _init_lp_fano1_Fano1_Module1_F128_one();
lean_mark_persistent(lp_fano1_Fano1_Module1_F128_one);
return lean_io_result_mk_ok(lean_box(0));
}
#ifdef __cplusplus
}
#endif
