// Lean compiler output
// Module: Fano1.Module3.Reconstruction
// Imports: public import Init public meta import Init public import Fano1.Module3.Folding
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
lean_object* lean_nat_mul(lean_object*, lean_object*);
LEAN_EXPORT lean_object* lp_fano1_Fano1_Module3_K__OPERATORS;
static lean_once_cell_t lp_fano1_Fano1_Module3_boundary__op___lam__0___closed__0_once = LEAN_ONCE_CELL_INITIALIZER;
static lean_object* lp_fano1_Fano1_Module3_boundary__op___lam__0___closed__0;
LEAN_EXPORT lean_object* lp_fano1_Fano1_Module3_boundary__op___lam__0(lean_object*);
LEAN_EXPORT lean_object* lp_fano1_Fano1_Module3_boundary__op___lam__0___boxed(lean_object*);
static const lean_closure_object lp_fano1_Fano1_Module3_boundary__op___closed__0_value = {.m_header = {.m_rc = 0, .m_cs_sz = sizeof(lean_closure_object) + sizeof(void*)*0, .m_other = 0, .m_tag = 245}, .m_fun = (void*)lp_fano1_Fano1_Module3_boundary__op___lam__0___boxed, .m_arity = 1, .m_num_fixed = 0, .m_objs = {} };
static const lean_object* lp_fano1_Fano1_Module3_boundary__op___closed__0 = (const lean_object*)&lp_fano1_Fano1_Module3_boundary__op___closed__0_value;
static const lean_ctor_object lp_fano1_Fano1_Module3_boundary__op___closed__1_value = {.m_header = {.m_rc = 0, .m_cs_sz = sizeof(lean_ctor_object) + sizeof(void*)*2 + 0, .m_other = 2, .m_tag = 0}, .m_objs = {((lean_object*)&lp_fano1_Fano1_Module3_boundary__op___closed__0_value),((lean_object*)&lp_fano1_Fano1_Module3_boundary__op___closed__0_value)}};
static const lean_object* lp_fano1_Fano1_Module3_boundary__op___closed__1 = (const lean_object*)&lp_fano1_Fano1_Module3_boundary__op___closed__1_value;
LEAN_EXPORT const lean_object* lp_fano1_Fano1_Module3_boundary__op = (const lean_object*)&lp_fano1_Fano1_Module3_boundary__op___closed__1_value;
LEAN_EXPORT lean_object* lp_fano1_Fano1_Module3_reconstruction__cost(lean_object*);
LEAN_EXPORT lean_object* lp_fano1_Fano1_Module3_reconstruction__cost___boxed(lean_object*);
static lean_object* _init_lp_fano1_Fano1_Module3_K__OPERATORS(void){
_start:
{
lean_object* v___x_1_; 
v___x_1_ = lean_unsigned_to_nat(8u);
return v___x_1_;
}
}
static lean_object* _init_lp_fano1_Fano1_Module3_boundary__op___lam__0___closed__0(void){
_start:
{
lean_object* v___x_2_; lean_object* v___x_3_; 
v___x_2_ = lean_unsigned_to_nat(0u);
v___x_3_ = lean_nat_to_int(v___x_2_);
return v___x_3_;
}
}
LEAN_EXPORT lean_object* lp_fano1_Fano1_Module3_boundary__op___lam__0(lean_object* v_x_4_){
_start:
{
lean_object* v___x_5_; 
v___x_5_ = lean_obj_once(&lp_fano1_Fano1_Module3_boundary__op___lam__0___closed__0, &lp_fano1_Fano1_Module3_boundary__op___lam__0___closed__0_once, _init_lp_fano1_Fano1_Module3_boundary__op___lam__0___closed__0);
return v___x_5_;
}
}
LEAN_EXPORT lean_object* lp_fano1_Fano1_Module3_boundary__op___lam__0___boxed(lean_object* v_x_6_){
_start:
{
lean_object* v_res_7_; 
v_res_7_ = lp_fano1_Fano1_Module3_boundary__op___lam__0(v_x_6_);
lean_dec(v_x_6_);
return v_res_7_;
}
}
LEAN_EXPORT lean_object* lp_fano1_Fano1_Module3_reconstruction__cost(lean_object* v_m_12_){
_start:
{
lean_object* v___x_13_; lean_object* v___x_14_; 
v___x_13_ = lean_unsigned_to_nat(32768u);
v___x_14_ = lean_nat_mul(v___x_13_, v_m_12_);
return v___x_14_;
}
}
LEAN_EXPORT lean_object* lp_fano1_Fano1_Module3_reconstruction__cost___boxed(lean_object* v_m_15_){
_start:
{
lean_object* v_res_16_; 
v_res_16_ = lp_fano1_Fano1_Module3_reconstruction__cost(v_m_15_);
lean_dec(v_m_15_);
return v_res_16_;
}
}
lean_object* initialize_Init(uint8_t builtin);
lean_object* initialize_Init(uint8_t builtin);
lean_object* initialize_fano1_Fano1_Module3_Folding(uint8_t builtin);
static bool _G_initialized = false;
LEAN_EXPORT lean_object* initialize_fano1_Fano1_Module3_Reconstruction(uint8_t builtin) {
lean_object * res;
if (_G_initialized) return lean_io_result_mk_ok(lean_box(0));
_G_initialized = true;
res = initialize_Init(builtin);
if (lean_io_result_is_error(res)) return res;
lean_dec_ref(res);
res = initialize_Init(builtin);
if (lean_io_result_is_error(res)) return res;
lean_dec_ref(res);
res = initialize_fano1_Fano1_Module3_Folding(builtin);
if (lean_io_result_is_error(res)) return res;
lean_dec_ref(res);
lp_fano1_Fano1_Module3_K__OPERATORS = _init_lp_fano1_Fano1_Module3_K__OPERATORS();
lean_mark_persistent(lp_fano1_Fano1_Module3_K__OPERATORS);
return lean_io_result_mk_ok(lean_box(0));
}
#ifdef __cplusplus
}
#endif
