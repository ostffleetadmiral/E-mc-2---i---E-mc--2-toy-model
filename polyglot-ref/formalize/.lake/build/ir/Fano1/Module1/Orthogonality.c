// Lean compiler output
// Module: Fano1.Module1.Orthogonality
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
lean_object* lean_int_mul(lean_object*, lean_object*);
lean_object* lean_int_sub(lean_object*, lean_object*);
lean_object* lean_int_add(lean_object*, lean_object*);
lean_object* lean_int_neg(lean_object*);
LEAN_EXPORT lean_object* lp_fano1_Fano1_Module1_Vec2_rotate(lean_object*);
LEAN_EXPORT lean_object* lp_fano1_Fano1_Module1_Vec2_dot(lean_object*, lean_object*);
LEAN_EXPORT lean_object* lp_fano1_Fano1_Module1_Vec2_dot___boxed(lean_object*, lean_object*);
LEAN_EXPORT lean_object* lp_fano1_Fano1_Module1_Vec2_pythagoreanRotate(lean_object*, lean_object*, lean_object*);
LEAN_EXPORT lean_object* lp_fano1_Fano1_Module1_Vec2_pythagoreanRotate___boxed(lean_object*, lean_object*, lean_object*);
LEAN_EXPORT lean_object* lp_fano1_Fano1_Module1_Vec2_rotate(lean_object* v_v_1_){
_start:
{
lean_object* v_x_2_; lean_object* v_y_3_; lean_object* v___x_5_; uint8_t v_isShared_6_; uint8_t v_isSharedCheck_11_; 
v_x_2_ = lean_ctor_get(v_v_1_, 0);
v_y_3_ = lean_ctor_get(v_v_1_, 1);
v_isSharedCheck_11_ = !lean_is_exclusive(v_v_1_);
if (v_isSharedCheck_11_ == 0)
{
v___x_5_ = v_v_1_;
v_isShared_6_ = v_isSharedCheck_11_;
goto v_resetjp_4_;
}
else
{
lean_inc(v_y_3_);
lean_inc(v_x_2_);
lean_dec(v_v_1_);
v___x_5_ = lean_box(0);
v_isShared_6_ = v_isSharedCheck_11_;
goto v_resetjp_4_;
}
v_resetjp_4_:
{
lean_object* v___x_7_; lean_object* v___x_9_; 
v___x_7_ = lean_int_neg(v_y_3_);
lean_dec(v_y_3_);
if (v_isShared_6_ == 0)
{
lean_ctor_set(v___x_5_, 1, v_x_2_);
lean_ctor_set(v___x_5_, 0, v___x_7_);
v___x_9_ = v___x_5_;
goto v_reusejp_8_;
}
else
{
lean_object* v_reuseFailAlloc_10_; 
v_reuseFailAlloc_10_ = lean_alloc_ctor(0, 2, 0);
lean_ctor_set(v_reuseFailAlloc_10_, 0, v___x_7_);
lean_ctor_set(v_reuseFailAlloc_10_, 1, v_x_2_);
v___x_9_ = v_reuseFailAlloc_10_;
goto v_reusejp_8_;
}
v_reusejp_8_:
{
return v___x_9_;
}
}
}
}
LEAN_EXPORT lean_object* lp_fano1_Fano1_Module1_Vec2_dot(lean_object* v_u_12_, lean_object* v_v_13_){
_start:
{
lean_object* v_x_14_; lean_object* v_y_15_; lean_object* v_x_16_; lean_object* v_y_17_; lean_object* v___x_18_; lean_object* v___x_19_; lean_object* v___x_20_; 
v_x_14_ = lean_ctor_get(v_u_12_, 0);
v_y_15_ = lean_ctor_get(v_u_12_, 1);
v_x_16_ = lean_ctor_get(v_v_13_, 0);
v_y_17_ = lean_ctor_get(v_v_13_, 1);
v___x_18_ = lean_int_mul(v_x_14_, v_x_16_);
v___x_19_ = lean_int_mul(v_y_15_, v_y_17_);
v___x_20_ = lean_int_add(v___x_18_, v___x_19_);
lean_dec(v___x_19_);
lean_dec(v___x_18_);
return v___x_20_;
}
}
LEAN_EXPORT lean_object* lp_fano1_Fano1_Module1_Vec2_dot___boxed(lean_object* v_u_21_, lean_object* v_v_22_){
_start:
{
lean_object* v_res_23_; 
v_res_23_ = lp_fano1_Fano1_Module1_Vec2_dot(v_u_21_, v_v_22_);
lean_dec_ref(v_v_22_);
lean_dec_ref(v_u_21_);
return v_res_23_;
}
}
LEAN_EXPORT lean_object* lp_fano1_Fano1_Module1_Vec2_pythagoreanRotate(lean_object* v_v_24_, lean_object* v_c_25_, lean_object* v_s_26_){
_start:
{
lean_object* v_x_27_; lean_object* v_y_28_; lean_object* v___x_30_; uint8_t v_isShared_31_; uint8_t v_isSharedCheck_41_; 
v_x_27_ = lean_ctor_get(v_v_24_, 0);
v_y_28_ = lean_ctor_get(v_v_24_, 1);
v_isSharedCheck_41_ = !lean_is_exclusive(v_v_24_);
if (v_isSharedCheck_41_ == 0)
{
v___x_30_ = v_v_24_;
v_isShared_31_ = v_isSharedCheck_41_;
goto v_resetjp_29_;
}
else
{
lean_inc(v_y_28_);
lean_inc(v_x_27_);
lean_dec(v_v_24_);
v___x_30_ = lean_box(0);
v_isShared_31_ = v_isSharedCheck_41_;
goto v_resetjp_29_;
}
v_resetjp_29_:
{
lean_object* v___x_32_; lean_object* v___x_33_; lean_object* v___x_34_; lean_object* v___x_35_; lean_object* v___x_36_; lean_object* v___x_37_; lean_object* v___x_39_; 
v___x_32_ = lean_int_mul(v_c_25_, v_x_27_);
v___x_33_ = lean_int_mul(v_s_26_, v_y_28_);
v___x_34_ = lean_int_sub(v___x_32_, v___x_33_);
lean_dec(v___x_33_);
lean_dec(v___x_32_);
v___x_35_ = lean_int_mul(v_s_26_, v_x_27_);
lean_dec(v_x_27_);
v___x_36_ = lean_int_mul(v_c_25_, v_y_28_);
lean_dec(v_y_28_);
v___x_37_ = lean_int_add(v___x_35_, v___x_36_);
lean_dec(v___x_36_);
lean_dec(v___x_35_);
if (v_isShared_31_ == 0)
{
lean_ctor_set(v___x_30_, 1, v___x_37_);
lean_ctor_set(v___x_30_, 0, v___x_34_);
v___x_39_ = v___x_30_;
goto v_reusejp_38_;
}
else
{
lean_object* v_reuseFailAlloc_40_; 
v_reuseFailAlloc_40_ = lean_alloc_ctor(0, 2, 0);
lean_ctor_set(v_reuseFailAlloc_40_, 0, v___x_34_);
lean_ctor_set(v_reuseFailAlloc_40_, 1, v___x_37_);
v___x_39_ = v_reuseFailAlloc_40_;
goto v_reusejp_38_;
}
v_reusejp_38_:
{
return v___x_39_;
}
}
}
}
LEAN_EXPORT lean_object* lp_fano1_Fano1_Module1_Vec2_pythagoreanRotate___boxed(lean_object* v_v_42_, lean_object* v_c_43_, lean_object* v_s_44_){
_start:
{
lean_object* v_res_45_; 
v_res_45_ = lp_fano1_Fano1_Module1_Vec2_pythagoreanRotate(v_v_42_, v_c_43_, v_s_44_);
lean_dec(v_s_44_);
lean_dec(v_c_43_);
return v_res_45_;
}
}
lean_object* initialize_Init(uint8_t builtin);
lean_object* initialize_Init(uint8_t builtin);
lean_object* initialize_fano1_Fano1_Module1_FixedPoint(uint8_t builtin);
static bool _G_initialized = false;
LEAN_EXPORT lean_object* initialize_fano1_Fano1_Module1_Orthogonality(uint8_t builtin) {
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
