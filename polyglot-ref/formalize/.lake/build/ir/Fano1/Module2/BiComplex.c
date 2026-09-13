// Lean compiler output
// Module: Fano1.Module2.BiComplex
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
lean_object* lean_int_neg(lean_object*);
lean_object* lean_int_add(lean_object*, lean_object*);
lean_object* lean_int_mul(lean_object*, lean_object*);
lean_object* lean_int_sub(lean_object*, lean_object*);
static lean_once_cell_t lp_fano1_Fano1_Module2_BiComplex_zero___closed__0_once = LEAN_ONCE_CELL_INITIALIZER;
static lean_object* lp_fano1_Fano1_Module2_BiComplex_zero___closed__0;
static lean_once_cell_t lp_fano1_Fano1_Module2_BiComplex_zero___closed__1_once = LEAN_ONCE_CELL_INITIALIZER;
static lean_object* lp_fano1_Fano1_Module2_BiComplex_zero___closed__1;
LEAN_EXPORT lean_object* lp_fano1_Fano1_Module2_BiComplex_zero;
static lean_once_cell_t lp_fano1_Fano1_Module2_BiComplex_one___closed__0_once = LEAN_ONCE_CELL_INITIALIZER;
static lean_object* lp_fano1_Fano1_Module2_BiComplex_one___closed__0;
static lean_once_cell_t lp_fano1_Fano1_Module2_BiComplex_one___closed__1_once = LEAN_ONCE_CELL_INITIALIZER;
static lean_object* lp_fano1_Fano1_Module2_BiComplex_one___closed__1;
LEAN_EXPORT lean_object* lp_fano1_Fano1_Module2_BiComplex_one;
LEAN_EXPORT lean_object* lp_fano1_Fano1_Module2_BiComplex_add(lean_object*, lean_object*);
LEAN_EXPORT lean_object* lp_fano1_Fano1_Module2_BiComplex_add___boxed(lean_object*, lean_object*);
LEAN_EXPORT lean_object* lp_fano1_Fano1_Module2_BiComplex_mul(lean_object*, lean_object*);
LEAN_EXPORT lean_object* lp_fano1_Fano1_Module2_BiComplex_mul___boxed(lean_object*, lean_object*);
LEAN_EXPORT lean_object* lp_fano1_Fano1_Module2_BiComplex_neg(lean_object*);
static lean_once_cell_t lp_fano1_Fano1_Module2_ePlus___closed__0_once = LEAN_ONCE_CELL_INITIALIZER;
static lean_object* lp_fano1_Fano1_Module2_ePlus___closed__0;
LEAN_EXPORT lean_object* lp_fano1_Fano1_Module2_ePlus;
static lean_once_cell_t lp_fano1_Fano1_Module2_eMinus___closed__0_once = LEAN_ONCE_CELL_INITIALIZER;
static lean_object* lp_fano1_Fano1_Module2_eMinus___closed__0;
LEAN_EXPORT lean_object* lp_fano1_Fano1_Module2_eMinus;
static lean_object* _init_lp_fano1_Fano1_Module2_BiComplex_zero___closed__0(void){
_start:
{
lean_object* v___x_1_; lean_object* v___x_2_; 
v___x_1_ = lean_unsigned_to_nat(0u);
v___x_2_ = lean_nat_to_int(v___x_1_);
return v___x_2_;
}
}
static lean_object* _init_lp_fano1_Fano1_Module2_BiComplex_zero___closed__1(void){
_start:
{
lean_object* v___x_3_; lean_object* v___x_4_; 
v___x_3_ = lean_obj_once(&lp_fano1_Fano1_Module2_BiComplex_zero___closed__0, &lp_fano1_Fano1_Module2_BiComplex_zero___closed__0_once, _init_lp_fano1_Fano1_Module2_BiComplex_zero___closed__0);
v___x_4_ = lean_alloc_ctor(0, 4, 0);
lean_ctor_set(v___x_4_, 0, v___x_3_);
lean_ctor_set(v___x_4_, 1, v___x_3_);
lean_ctor_set(v___x_4_, 2, v___x_3_);
lean_ctor_set(v___x_4_, 3, v___x_3_);
return v___x_4_;
}
}
static lean_object* _init_lp_fano1_Fano1_Module2_BiComplex_zero(void){
_start:
{
lean_object* v___x_5_; 
v___x_5_ = lean_obj_once(&lp_fano1_Fano1_Module2_BiComplex_zero___closed__1, &lp_fano1_Fano1_Module2_BiComplex_zero___closed__1_once, _init_lp_fano1_Fano1_Module2_BiComplex_zero___closed__1);
return v___x_5_;
}
}
static lean_object* _init_lp_fano1_Fano1_Module2_BiComplex_one___closed__0(void){
_start:
{
lean_object* v___x_6_; lean_object* v___x_7_; 
v___x_6_ = lean_unsigned_to_nat(1u);
v___x_7_ = lean_nat_to_int(v___x_6_);
return v___x_7_;
}
}
static lean_object* _init_lp_fano1_Fano1_Module2_BiComplex_one___closed__1(void){
_start:
{
lean_object* v___x_8_; lean_object* v___x_9_; lean_object* v___x_10_; 
v___x_8_ = lean_obj_once(&lp_fano1_Fano1_Module2_BiComplex_zero___closed__0, &lp_fano1_Fano1_Module2_BiComplex_zero___closed__0_once, _init_lp_fano1_Fano1_Module2_BiComplex_zero___closed__0);
v___x_9_ = lean_obj_once(&lp_fano1_Fano1_Module2_BiComplex_one___closed__0, &lp_fano1_Fano1_Module2_BiComplex_one___closed__0_once, _init_lp_fano1_Fano1_Module2_BiComplex_one___closed__0);
v___x_10_ = lean_alloc_ctor(0, 4, 0);
lean_ctor_set(v___x_10_, 0, v___x_9_);
lean_ctor_set(v___x_10_, 1, v___x_8_);
lean_ctor_set(v___x_10_, 2, v___x_9_);
lean_ctor_set(v___x_10_, 3, v___x_8_);
return v___x_10_;
}
}
static lean_object* _init_lp_fano1_Fano1_Module2_BiComplex_one(void){
_start:
{
lean_object* v___x_11_; 
v___x_11_ = lean_obj_once(&lp_fano1_Fano1_Module2_BiComplex_one___closed__1, &lp_fano1_Fano1_Module2_BiComplex_one___closed__1_once, _init_lp_fano1_Fano1_Module2_BiComplex_one___closed__1);
return v___x_11_;
}
}
LEAN_EXPORT lean_object* lp_fano1_Fano1_Module2_BiComplex_add(lean_object* v_x_12_, lean_object* v_y_13_){
_start:
{
lean_object* v_re1_14_; lean_object* v_im1_15_; lean_object* v_re2_16_; lean_object* v_im2_17_; lean_object* v_re1_18_; lean_object* v_im1_19_; lean_object* v_re2_20_; lean_object* v_im2_21_; lean_object* v___x_23_; uint8_t v_isShared_24_; uint8_t v_isSharedCheck_32_; 
v_re1_14_ = lean_ctor_get(v_x_12_, 0);
v_im1_15_ = lean_ctor_get(v_x_12_, 1);
v_re2_16_ = lean_ctor_get(v_x_12_, 2);
v_im2_17_ = lean_ctor_get(v_x_12_, 3);
v_re1_18_ = lean_ctor_get(v_y_13_, 0);
v_im1_19_ = lean_ctor_get(v_y_13_, 1);
v_re2_20_ = lean_ctor_get(v_y_13_, 2);
v_im2_21_ = lean_ctor_get(v_y_13_, 3);
v_isSharedCheck_32_ = !lean_is_exclusive(v_y_13_);
if (v_isSharedCheck_32_ == 0)
{
v___x_23_ = v_y_13_;
v_isShared_24_ = v_isSharedCheck_32_;
goto v_resetjp_22_;
}
else
{
lean_inc(v_im2_21_);
lean_inc(v_re2_20_);
lean_inc(v_im1_19_);
lean_inc(v_re1_18_);
lean_dec(v_y_13_);
v___x_23_ = lean_box(0);
v_isShared_24_ = v_isSharedCheck_32_;
goto v_resetjp_22_;
}
v_resetjp_22_:
{
lean_object* v___x_25_; lean_object* v___x_26_; lean_object* v___x_27_; lean_object* v___x_28_; lean_object* v___x_30_; 
v___x_25_ = lean_int_add(v_re1_14_, v_re1_18_);
lean_dec(v_re1_18_);
v___x_26_ = lean_int_add(v_im1_15_, v_im1_19_);
lean_dec(v_im1_19_);
v___x_27_ = lean_int_add(v_re2_16_, v_re2_20_);
lean_dec(v_re2_20_);
v___x_28_ = lean_int_add(v_im2_17_, v_im2_21_);
lean_dec(v_im2_21_);
if (v_isShared_24_ == 0)
{
lean_ctor_set(v___x_23_, 3, v___x_28_);
lean_ctor_set(v___x_23_, 2, v___x_27_);
lean_ctor_set(v___x_23_, 1, v___x_26_);
lean_ctor_set(v___x_23_, 0, v___x_25_);
v___x_30_ = v___x_23_;
goto v_reusejp_29_;
}
else
{
lean_object* v_reuseFailAlloc_31_; 
v_reuseFailAlloc_31_ = lean_alloc_ctor(0, 4, 0);
lean_ctor_set(v_reuseFailAlloc_31_, 0, v___x_25_);
lean_ctor_set(v_reuseFailAlloc_31_, 1, v___x_26_);
lean_ctor_set(v_reuseFailAlloc_31_, 2, v___x_27_);
lean_ctor_set(v_reuseFailAlloc_31_, 3, v___x_28_);
v___x_30_ = v_reuseFailAlloc_31_;
goto v_reusejp_29_;
}
v_reusejp_29_:
{
return v___x_30_;
}
}
}
}
LEAN_EXPORT lean_object* lp_fano1_Fano1_Module2_BiComplex_add___boxed(lean_object* v_x_33_, lean_object* v_y_34_){
_start:
{
lean_object* v_res_35_; 
v_res_35_ = lp_fano1_Fano1_Module2_BiComplex_add(v_x_33_, v_y_34_);
lean_dec_ref(v_x_33_);
return v_res_35_;
}
}
LEAN_EXPORT lean_object* lp_fano1_Fano1_Module2_BiComplex_mul(lean_object* v_x_36_, lean_object* v_y_37_){
_start:
{
lean_object* v_re1_38_; lean_object* v_im1_39_; lean_object* v_re2_40_; lean_object* v_im2_41_; lean_object* v_re1_42_; lean_object* v_im1_43_; lean_object* v_re2_44_; lean_object* v_im2_45_; lean_object* v___x_47_; uint8_t v_isShared_48_; uint8_t v_isSharedCheck_64_; 
v_re1_38_ = lean_ctor_get(v_x_36_, 0);
v_im1_39_ = lean_ctor_get(v_x_36_, 1);
v_re2_40_ = lean_ctor_get(v_x_36_, 2);
v_im2_41_ = lean_ctor_get(v_x_36_, 3);
v_re1_42_ = lean_ctor_get(v_y_37_, 0);
v_im1_43_ = lean_ctor_get(v_y_37_, 1);
v_re2_44_ = lean_ctor_get(v_y_37_, 2);
v_im2_45_ = lean_ctor_get(v_y_37_, 3);
v_isSharedCheck_64_ = !lean_is_exclusive(v_y_37_);
if (v_isSharedCheck_64_ == 0)
{
v___x_47_ = v_y_37_;
v_isShared_48_ = v_isSharedCheck_64_;
goto v_resetjp_46_;
}
else
{
lean_inc(v_im2_45_);
lean_inc(v_re2_44_);
lean_inc(v_im1_43_);
lean_inc(v_re1_42_);
lean_dec(v_y_37_);
v___x_47_ = lean_box(0);
v_isShared_48_ = v_isSharedCheck_64_;
goto v_resetjp_46_;
}
v_resetjp_46_:
{
lean_object* v___x_49_; lean_object* v___x_50_; lean_object* v___x_51_; lean_object* v___x_52_; lean_object* v___x_53_; lean_object* v___x_54_; lean_object* v___x_55_; lean_object* v___x_56_; lean_object* v___x_57_; lean_object* v___x_58_; lean_object* v___x_59_; lean_object* v___x_60_; lean_object* v___x_62_; 
v___x_49_ = lean_int_mul(v_re1_38_, v_re1_42_);
v___x_50_ = lean_int_mul(v_im1_39_, v_im1_43_);
v___x_51_ = lean_int_sub(v___x_49_, v___x_50_);
lean_dec(v___x_50_);
lean_dec(v___x_49_);
v___x_52_ = lean_int_mul(v_re1_38_, v_im1_43_);
lean_dec(v_im1_43_);
v___x_53_ = lean_int_mul(v_im1_39_, v_re1_42_);
lean_dec(v_re1_42_);
v___x_54_ = lean_int_add(v___x_52_, v___x_53_);
lean_dec(v___x_53_);
lean_dec(v___x_52_);
v___x_55_ = lean_int_mul(v_re2_40_, v_re2_44_);
v___x_56_ = lean_int_mul(v_im2_41_, v_im2_45_);
v___x_57_ = lean_int_sub(v___x_55_, v___x_56_);
lean_dec(v___x_56_);
lean_dec(v___x_55_);
v___x_58_ = lean_int_mul(v_re2_40_, v_im2_45_);
lean_dec(v_im2_45_);
v___x_59_ = lean_int_mul(v_im2_41_, v_re2_44_);
lean_dec(v_re2_44_);
v___x_60_ = lean_int_add(v___x_58_, v___x_59_);
lean_dec(v___x_59_);
lean_dec(v___x_58_);
if (v_isShared_48_ == 0)
{
lean_ctor_set(v___x_47_, 3, v___x_60_);
lean_ctor_set(v___x_47_, 2, v___x_57_);
lean_ctor_set(v___x_47_, 1, v___x_54_);
lean_ctor_set(v___x_47_, 0, v___x_51_);
v___x_62_ = v___x_47_;
goto v_reusejp_61_;
}
else
{
lean_object* v_reuseFailAlloc_63_; 
v_reuseFailAlloc_63_ = lean_alloc_ctor(0, 4, 0);
lean_ctor_set(v_reuseFailAlloc_63_, 0, v___x_51_);
lean_ctor_set(v_reuseFailAlloc_63_, 1, v___x_54_);
lean_ctor_set(v_reuseFailAlloc_63_, 2, v___x_57_);
lean_ctor_set(v_reuseFailAlloc_63_, 3, v___x_60_);
v___x_62_ = v_reuseFailAlloc_63_;
goto v_reusejp_61_;
}
v_reusejp_61_:
{
return v___x_62_;
}
}
}
}
LEAN_EXPORT lean_object* lp_fano1_Fano1_Module2_BiComplex_mul___boxed(lean_object* v_x_65_, lean_object* v_y_66_){
_start:
{
lean_object* v_res_67_; 
v_res_67_ = lp_fano1_Fano1_Module2_BiComplex_mul(v_x_65_, v_y_66_);
lean_dec_ref(v_x_65_);
return v_res_67_;
}
}
LEAN_EXPORT lean_object* lp_fano1_Fano1_Module2_BiComplex_neg(lean_object* v_x_68_){
_start:
{
lean_object* v_re1_69_; lean_object* v_im1_70_; lean_object* v_re2_71_; lean_object* v_im2_72_; lean_object* v___x_74_; uint8_t v_isShared_75_; uint8_t v_isSharedCheck_83_; 
v_re1_69_ = lean_ctor_get(v_x_68_, 0);
v_im1_70_ = lean_ctor_get(v_x_68_, 1);
v_re2_71_ = lean_ctor_get(v_x_68_, 2);
v_im2_72_ = lean_ctor_get(v_x_68_, 3);
v_isSharedCheck_83_ = !lean_is_exclusive(v_x_68_);
if (v_isSharedCheck_83_ == 0)
{
v___x_74_ = v_x_68_;
v_isShared_75_ = v_isSharedCheck_83_;
goto v_resetjp_73_;
}
else
{
lean_inc(v_im2_72_);
lean_inc(v_re2_71_);
lean_inc(v_im1_70_);
lean_inc(v_re1_69_);
lean_dec(v_x_68_);
v___x_74_ = lean_box(0);
v_isShared_75_ = v_isSharedCheck_83_;
goto v_resetjp_73_;
}
v_resetjp_73_:
{
lean_object* v___x_76_; lean_object* v___x_77_; lean_object* v___x_78_; lean_object* v___x_79_; lean_object* v___x_81_; 
v___x_76_ = lean_int_neg(v_re1_69_);
lean_dec(v_re1_69_);
v___x_77_ = lean_int_neg(v_im1_70_);
lean_dec(v_im1_70_);
v___x_78_ = lean_int_neg(v_re2_71_);
lean_dec(v_re2_71_);
v___x_79_ = lean_int_neg(v_im2_72_);
lean_dec(v_im2_72_);
if (v_isShared_75_ == 0)
{
lean_ctor_set(v___x_74_, 3, v___x_79_);
lean_ctor_set(v___x_74_, 2, v___x_78_);
lean_ctor_set(v___x_74_, 1, v___x_77_);
lean_ctor_set(v___x_74_, 0, v___x_76_);
v___x_81_ = v___x_74_;
goto v_reusejp_80_;
}
else
{
lean_object* v_reuseFailAlloc_82_; 
v_reuseFailAlloc_82_ = lean_alloc_ctor(0, 4, 0);
lean_ctor_set(v_reuseFailAlloc_82_, 0, v___x_76_);
lean_ctor_set(v_reuseFailAlloc_82_, 1, v___x_77_);
lean_ctor_set(v_reuseFailAlloc_82_, 2, v___x_78_);
lean_ctor_set(v_reuseFailAlloc_82_, 3, v___x_79_);
v___x_81_ = v_reuseFailAlloc_82_;
goto v_reusejp_80_;
}
v_reusejp_80_:
{
return v___x_81_;
}
}
}
}
static lean_object* _init_lp_fano1_Fano1_Module2_ePlus___closed__0(void){
_start:
{
lean_object* v___x_84_; lean_object* v___x_85_; lean_object* v___x_86_; 
v___x_84_ = lean_obj_once(&lp_fano1_Fano1_Module2_BiComplex_zero___closed__0, &lp_fano1_Fano1_Module2_BiComplex_zero___closed__0_once, _init_lp_fano1_Fano1_Module2_BiComplex_zero___closed__0);
v___x_85_ = lean_obj_once(&lp_fano1_Fano1_Module2_BiComplex_one___closed__0, &lp_fano1_Fano1_Module2_BiComplex_one___closed__0_once, _init_lp_fano1_Fano1_Module2_BiComplex_one___closed__0);
v___x_86_ = lean_alloc_ctor(0, 4, 0);
lean_ctor_set(v___x_86_, 0, v___x_85_);
lean_ctor_set(v___x_86_, 1, v___x_84_);
lean_ctor_set(v___x_86_, 2, v___x_84_);
lean_ctor_set(v___x_86_, 3, v___x_84_);
return v___x_86_;
}
}
static lean_object* _init_lp_fano1_Fano1_Module2_ePlus(void){
_start:
{
lean_object* v___x_87_; 
v___x_87_ = lean_obj_once(&lp_fano1_Fano1_Module2_ePlus___closed__0, &lp_fano1_Fano1_Module2_ePlus___closed__0_once, _init_lp_fano1_Fano1_Module2_ePlus___closed__0);
return v___x_87_;
}
}
static lean_object* _init_lp_fano1_Fano1_Module2_eMinus___closed__0(void){
_start:
{
lean_object* v___x_88_; lean_object* v___x_89_; lean_object* v___x_90_; 
v___x_88_ = lean_obj_once(&lp_fano1_Fano1_Module2_BiComplex_one___closed__0, &lp_fano1_Fano1_Module2_BiComplex_one___closed__0_once, _init_lp_fano1_Fano1_Module2_BiComplex_one___closed__0);
v___x_89_ = lean_obj_once(&lp_fano1_Fano1_Module2_BiComplex_zero___closed__0, &lp_fano1_Fano1_Module2_BiComplex_zero___closed__0_once, _init_lp_fano1_Fano1_Module2_BiComplex_zero___closed__0);
v___x_90_ = lean_alloc_ctor(0, 4, 0);
lean_ctor_set(v___x_90_, 0, v___x_89_);
lean_ctor_set(v___x_90_, 1, v___x_89_);
lean_ctor_set(v___x_90_, 2, v___x_88_);
lean_ctor_set(v___x_90_, 3, v___x_89_);
return v___x_90_;
}
}
static lean_object* _init_lp_fano1_Fano1_Module2_eMinus(void){
_start:
{
lean_object* v___x_91_; 
v___x_91_ = lean_obj_once(&lp_fano1_Fano1_Module2_eMinus___closed__0, &lp_fano1_Fano1_Module2_eMinus___closed__0_once, _init_lp_fano1_Fano1_Module2_eMinus___closed__0);
return v___x_91_;
}
}
lean_object* initialize_Init(uint8_t builtin);
lean_object* initialize_Init(uint8_t builtin);
lean_object* initialize_fano1_Fano1_Module1_FixedPoint(uint8_t builtin);
static bool _G_initialized = false;
LEAN_EXPORT lean_object* initialize_fano1_Fano1_Module2_BiComplex(uint8_t builtin) {
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
lp_fano1_Fano1_Module2_BiComplex_zero = _init_lp_fano1_Fano1_Module2_BiComplex_zero();
lean_mark_persistent(lp_fano1_Fano1_Module2_BiComplex_zero);
lp_fano1_Fano1_Module2_BiComplex_one = _init_lp_fano1_Fano1_Module2_BiComplex_one();
lean_mark_persistent(lp_fano1_Fano1_Module2_BiComplex_one);
lp_fano1_Fano1_Module2_ePlus = _init_lp_fano1_Fano1_Module2_ePlus();
lean_mark_persistent(lp_fano1_Fano1_Module2_ePlus);
lp_fano1_Fano1_Module2_eMinus = _init_lp_fano1_Fano1_Module2_eMinus();
lean_mark_persistent(lp_fano1_Fano1_Module2_eMinus);
return lean_io_result_mk_ok(lean_box(0));
}
#ifdef __cplusplus
}
#endif
