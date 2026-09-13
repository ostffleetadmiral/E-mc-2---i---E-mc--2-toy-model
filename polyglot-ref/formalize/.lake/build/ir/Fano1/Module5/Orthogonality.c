// Lean compiler output
// Module: Fano1.Module5.Orthogonality
// Imports: public import Init public meta import Init public import Fano1.Module1.FixedPoint public import Fano1.Module1.Orthogonality
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
lean_object* lean_int_mul(lean_object*, lean_object*);
lean_object* lean_int_add(lean_object*, lean_object*);
lean_object* l_List_zipWith___at___00List_zip_spec__0___redArg(lean_object*, lean_object*);
LEAN_EXPORT lean_object* lp_fano1_List_foldl___at___00Fano1_Module5_list__inner_spec__0(lean_object*, lean_object*);
LEAN_EXPORT lean_object* lp_fano1_List_foldl___at___00Fano1_Module5_list__inner_spec__0___boxed(lean_object*, lean_object*);
static lean_once_cell_t lp_fano1_Fano1_Module5_list__inner___closed__0_once = LEAN_ONCE_CELL_INITIALIZER;
static lean_object* lp_fano1_Fano1_Module5_list__inner___closed__0;
LEAN_EXPORT lean_object* lp_fano1_Fano1_Module5_list__inner(lean_object*, lean_object*);
LEAN_EXPORT lean_object* lp_fano1_List_foldl___at___00Fano1_Module5_list__inner_spec__0(lean_object* v_x_1_, lean_object* v_x_2_){
_start:
{
if (lean_obj_tag(v_x_2_) == 0)
{
return v_x_1_;
}
else
{
lean_object* v_head_3_; lean_object* v_tail_4_; lean_object* v_fst_5_; lean_object* v_snd_6_; lean_object* v___x_7_; lean_object* v___x_8_; 
v_head_3_ = lean_ctor_get(v_x_2_, 0);
v_tail_4_ = lean_ctor_get(v_x_2_, 1);
v_fst_5_ = lean_ctor_get(v_head_3_, 0);
v_snd_6_ = lean_ctor_get(v_head_3_, 1);
v___x_7_ = lean_int_mul(v_fst_5_, v_snd_6_);
v___x_8_ = lean_int_add(v_x_1_, v___x_7_);
lean_dec(v___x_7_);
lean_dec(v_x_1_);
v_x_1_ = v___x_8_;
v_x_2_ = v_tail_4_;
goto _start;
}
}
}
LEAN_EXPORT lean_object* lp_fano1_List_foldl___at___00Fano1_Module5_list__inner_spec__0___boxed(lean_object* v_x_10_, lean_object* v_x_11_){
_start:
{
lean_object* v_res_12_; 
v_res_12_ = lp_fano1_List_foldl___at___00Fano1_Module5_list__inner_spec__0(v_x_10_, v_x_11_);
lean_dec(v_x_11_);
return v_res_12_;
}
}
static lean_object* _init_lp_fano1_Fano1_Module5_list__inner___closed__0(void){
_start:
{
lean_object* v___x_13_; lean_object* v___x_14_; 
v___x_13_ = lean_unsigned_to_nat(0u);
v___x_14_ = lean_nat_to_int(v___x_13_);
return v___x_14_;
}
}
LEAN_EXPORT lean_object* lp_fano1_Fano1_Module5_list__inner(lean_object* v_xs_15_, lean_object* v_ys_16_){
_start:
{
lean_object* v___x_17_; lean_object* v___x_18_; lean_object* v___x_19_; 
v___x_17_ = lean_obj_once(&lp_fano1_Fano1_Module5_list__inner___closed__0, &lp_fano1_Fano1_Module5_list__inner___closed__0_once, _init_lp_fano1_Fano1_Module5_list__inner___closed__0);
v___x_18_ = l_List_zipWith___at___00List_zip_spec__0___redArg(v_xs_15_, v_ys_16_);
v___x_19_ = lp_fano1_List_foldl___at___00Fano1_Module5_list__inner_spec__0(v___x_17_, v___x_18_);
lean_dec(v___x_18_);
return v___x_19_;
}
}
lean_object* initialize_Init(uint8_t builtin);
lean_object* initialize_Init(uint8_t builtin);
lean_object* initialize_fano1_Fano1_Module1_FixedPoint(uint8_t builtin);
lean_object* initialize_fano1_Fano1_Module1_Orthogonality(uint8_t builtin);
static bool _G_initialized = false;
LEAN_EXPORT lean_object* initialize_fano1_Fano1_Module5_Orthogonality(uint8_t builtin) {
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
res = initialize_fano1_Fano1_Module1_Orthogonality(builtin);
if (lean_io_result_is_error(res)) return res;
lean_dec_ref(res);
return lean_io_result_mk_ok(lean_box(0));
}
#ifdef __cplusplus
}
#endif
