
Require Export Base.
Require Export Env.
Require Import Coq.Strings.String.


(* Types ************************************************************)
Inductive tycon : Type :=
 | TyConData   : string -> tycon.
Hint Constructors tycon.

Inductive ty : Type :=
 | TCon   : tycon -> ty
 | TFun   : ty    -> ty -> ty.
Hint Constructors ty.


(* Expressions ******************************************************
   We use deBruijn indices for binders.
 *)
Inductive datacon : Type :=
 | DataCon    : string -> datacon.
Hint Constructors datacon.


Inductive exp : Type :=
 (* Functions *)
 | XVar   : nat -> exp
 | XLam   : ty  -> exp -> exp
 | XApp   : exp -> exp -> exp

 (* Data Types *)
 | XCon   : datacon -> list exp -> exp
 | XCase  : exp     -> list alt -> exp

 (* Alternatives *)
with alt     : Type :=
 | AAlt   : datacon -> list ty  -> exp -> alt.

Hint Constructors exp.
Hint Constructors alt.


(* Mutual induction principle for expressions.
   As expressions are indirectly mutually recursive with lists,
   Coq's Combined scheme command won't make us a strong enough
   induction principle, so we need to write it out by hand. *)
Theorem exp_mutind
 : forall 
    (PX : exp -> Prop)
    (PA : alt -> Prop)
 ,  (forall n,                                PX (XVar n))
 -> (forall t  x1,   PX x1                 -> PX (XLam t x1))
 -> (forall x1 x2,   PX x1 -> PX x2        -> PX (XApp x1 x2))
 -> (forall dc xs,            Forall PX xs -> PX (XCon dc xs))
 -> (forall x  aa,   PX x  -> Forall PA aa -> PX (XCase x aa))
 -> (forall dc ts x, PX x                  -> PA (AAlt dc ts x))
 ->  forall x, PX x.
Proof. 
 intros PX PA.
 intros var lam app con case alt.
 refine (fix  IHX x : PX x := _
         with IHA a : PA a := _
         for  IHX).

 (* expressions *)
 case x; intros.

 Case "XVar".
  apply var.

 Case "XLam".
  apply lam. 
   apply IHX.

 Case "XApp".
  apply app. 
   apply IHX.
   apply IHX.

 Case "XCon".
  apply con.
   induction l; intuition.

 Case "XCase".
  apply case.
   apply IHX.
   induction l; intuition.

 (* alternatives *)
 case a; intros.

 Case "XAlt".
  apply alt.
   apply IHX.
Qed.


(* Definitions ******************************************************)
Inductive def  : Type :=
 (* Definition of a data type constructor *)
 | DefDataType 
   :  tycon        (* Name of data type constructor *)
   -> list datacon (* Data constructors that belong to this type *)
   -> def

 (* Definition of a data constructor *)
 | DefData 
   :  datacon      (* Name of data constructor *)
   -> list ty      (* Types of arguments *)
   -> ty           (* Type  of constructed data *)
   -> def.
Hint Constructors def.


(* Type Environments ************************************************)
Definition tyenv := env ty.
Definition defs  := env def.

Fixpoint getDataDef (dc: datacon) (ds: defs) : option def := 
 match ds with 
 | Empty                       => None
 | ds' :> DefData dc _ _ as d  => Some d
 | ds' :> _                    => getDataDef dc ds'
 end.

