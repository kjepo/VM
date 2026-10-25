/*
 *
 *	An industrious SECD-machine.
 *
 *	Ref: "Functional Programming", Field and Harrison.
 *
 */

#include <stdio.h>
#include <stdlib.h>

typedef enum {ID, LAM, APP, AT} exptag;
typedef enum {INT, PRIM, CLOSURE} whnftag;
typedef enum {PLUS, MINUS, IF} primop;			/* no primops yet */

typedef struct exp_cell {
  struct exp_cell *next;
  exptag tag;
  union {
    char id;				/* ID */
    struct {				/* LAM */
      char bv;
      struct exp_cell *body;
    } lam;
    struct {				/* APP */
      struct exp_cell *rator;
      struct exp_cell *rand;
    } app;
  } expkind;
} *EXP;

void print_exp(EXP e);

typedef struct whnf_cell {
  struct whnf_cell *next;
  whnftag tag;
  union {
    int num;				/* INT */
    primop prim;			/* PRIM */
    struct {				/* CLOSURE */
      struct exp_cell *exp;
      char bv;
      struct env_cell *envl;
    } clos;
  } whnfkind;
} *WHNF;

typedef struct env_cell {
  struct env_cell *next;
  char name;
  struct whnf_cell *value;
} *ENV;

void print_env(ENV e);

typedef struct state_cell {
  WHNF stack;
  ENV environment;
  EXP control;
  struct state_cell *dump;
} *STATE;

void print_dump(STATE s);

#define MKWHNF(w)	if (!(w = (WHNF) malloc(sizeof(struct whnf_cell)))) \
    fprintf(stderr, "MKWHNF out of memory\n"), exit(1)
#define MKEXP(e)	if (!(e = (EXP) malloc(sizeof(struct exp_cell)))) \
    fprintf(stderr, "MKEXP out of memory\n"), exit(1)
#define MKENV(e)	if (!(e = (ENV) malloc(sizeof(struct env_cell)))) \
    fprintf(stderr, "MKENV out of memory\n"), exit(1)
#define MKSTATE(s)	if (!(s = (STATE) malloc(sizeof(struct state_cell)))) \
    fprintf(stderr, "MKSTATE out of memory\n"), exit(1)

EXP mkid(char id) {
  EXP e;

  MKEXP(e);
  e->next = 0;
  e->tag = ID;
  e->expkind.id = id;
  return e;
}

EXP mklam(char bv, EXP body) {
  EXP e;
	
  MKEXP(e);
  e->next = 0;
  e->tag = LAM;
  e->expkind.lam.bv = bv;
  e->expkind.lam.body = body;
  return e;
}

EXP mkapp(EXP rator, EXP rand) {
  EXP e;

  MKEXP(e);
  e->next = 0;
  e->tag = APP;
  e->expkind.app.rator = rator;
  e->expkind.app.rand = rand;
  return e;
}

EXP mkat() {
  EXP e;

  MKEXP(e);
  e->next = 0;
  e->tag = AT;
  return e;
}

WHNF mkint(int num) {
  WHNF w;

  MKWHNF(w);
  w->next = 0;
  w->tag = INT;
  w->whnfkind.num = num;
  return w;
}

/* the stack and control lists are threaded through next, so cells
   that may be shared are copied before they are linked into a list */

EXP copyexp(EXP e) {
  EXP ne;

  MKEXP(ne);
  *ne = *e;
  ne->next = 0;
  return ne;
}

WHNF copywhnf(WHNF w) {
  WHNF nw;

  MKWHNF(nw);
  *nw = *w;
  nw->next = 0;
  return nw;
}

void update(char name, WHNF value, STATE machine) {
  ENV e;

  MKENV(e);
  e->name = name;
  e->value = value;
  e->next = machine->environment;
  machine->environment = e;
}

WHNF valueof(char id, ENV env) {
  for (; env; env = env->next)
    if (id == env->name)
      return (env->value);
  fprintf(stderr, "fatal: identifier %c not bound in environment\n", id);
  exit(1);
}

void push(WHNF w, STATE machine) {
  w = copywhnf(w);
  w->next = machine->stack;
  machine->stack = w;
}

WHNF mkclosure(EXP exp, char bv, ENV envl) {
  WHNF nw;

  MKWHNF(nw);
  nw->next = 0;
  nw->tag = CLOSURE;
  nw->whnfkind.clos.exp = exp;
  nw->whnfkind.clos.bv = bv;
  nw->whnfkind.clos.envl = envl;
  return nw;
}

void print_whnf(WHNF s) {
  if (s) {
    switch (s->tag) {
    case INT:
      printf("%d", s->whnfkind.num);
      break;
    case PRIM:
      printf("prim");	/* no prims yet */
      break;
    case CLOSURE:
      putchar('<');
      print_exp(s->whnfkind.clos.exp);
      putchar(',');
      putchar(s->whnfkind.clos.bv);
      putchar(',');
      print_env(s->whnfkind.clos.envl);
      putchar('>');
      break;
    }
    print_whnf(s->next);
  }
}

void print_env(ENV e) {
  if (e) {
    putchar('[');
    putchar(e->name);
    printf("->");
    print_whnf(e->value);
    putchar(']');
    print_env(e->next);
  }

}

void print_exp(EXP e) {
  if (e) {
    switch (e->tag) {
    case ID:
      printf("%c", e->expkind.id);
      break;
    case LAM:
      printf("\\%c.", e->expkind.lam.bv);
      print_exp(e->expkind.lam.body);
      break;
    case APP:
      print_exp(e->expkind.app.rator);
      putchar('(');
      print_exp(e->expkind.app.rand);
      putchar(')');
      break;
    case AT:
      putchar('@');
      break;
    }
    print_exp(e->next);
  }
}

void print_dump(STATE s) {
  if (s) {
    putchar('<');
    print_whnf(s->stack);
    putchar(',');
    print_env(s->environment);
    putchar(',');
    print_exp(s->control);
    putchar('>');
    print_dump(s->dump);
  }
}
	
void dbg(STATE machine) {
  printf("\nSTACK      : ");
  print_whnf(machine->stack);
  printf("\nENVIRONMENT: ");
  print_env(machine->environment);
  printf("\nCONTROL    : ");
  print_exp(machine->control);
  printf("\nDUMP       : ");
  print_dump(machine->dump);
  putchar('\n');
}

int main() {
  char V;
  EXP x, e, F, A, B;
  WHNF f, a, sprim;
  ENV Eprim, ne;
  STATE machine, dmp;

  /* some handy definitions */

  EXP Z, tru, fls, zero, succ, plus, times, pred, iszero, one, H, fac ;
	
  MKSTATE(machine);
  machine->stack = 0;
  machine->environment = 0;
  machine->dump = 0;

  /* set up the initial environment here */
	
  update('y', mkint(3), machine);
  update('x', mkint(4), machine);

  /* program the machine here */

  // Z: 𝜆 𝑓 . (𝜆𝑥. 𝑓 (𝜆𝑦. 𝑥 𝑥 𝑦)) (𝜆𝑥. 𝑓 (𝜆𝑦. 𝑥 𝑥 𝑦))
  Z = mklam('f',
	    mkapp(
		  mklam('x', mkapp(mkid('f'), mklam('y', mkapp(mkapp(mkid('x'), mkid('x')), mkid('y'))))),
		  mklam('x', mkapp(mkid('f'), mklam('y', mkapp(mkapp(mkid('x'), mkid('x')), mkid('y')))))));		  

  // true: 𝜆𝑥𝑦.𝑥
  tru = mklam('x', mklam('y', mkid('x')));

  // false: 𝜆𝑥𝑦.𝑦
  fls = mklam('x', mklam('y', mkid('y')));

  // 0: λf.λx.x
  zero = mklam('f', mklam('x', mkid('x')));

  // 1: λf.λx.f x
  one = mklam('f', mklam('x', mkapp(mkid('f'), mkid('x'))));

  // succ: λx.λy.λz.y (x y z)
  succ = mklam('x',
	       mklam('y',
		     mklam('z',
			   mkapp(mkid('y'), mkapp(mkapp(mkid('x'), mkid('y')), mkid('z'))))));

  // plus: λm.λn.λf.λx.m f (n f x)
  plus = mklam('m', mklam('n', mklam('f', mklam('x',
						mkapp(mkapp(mkid('m'), mkid('f')), mkapp(mkapp(mkid('n'), mkid('f')), mkid('x')))))));

  // times: λm.λn.λf.m (n f)
  times = mklam('m', mklam('n', mklam('f',
				      mkapp(mkid('m'), mkapp(mkid('n'), mkid('f'))))));

  // pred: λn.λf.λx.n (λg.λh.h (g f)) (λu.x) (λu.u)
  pred = mklam('n', mklam('f', mklam('x',
				     mkapp(mkapp(mkapp(mkid('n'),
						       mklam('g', mklam('h', mkapp(mkid('h'), mkapp(mkid('g'), mkid('f')))))),
						 mklam('u', mkid('x'))),
					   mklam('u', mkid('u'))))));

  // iszero: λn.n (λx.false) true
  iszero = mklam('n', mkapp(mkapp(mkid('n'), mklam('x', fls)), tru));

  // iszero(n) returns true or false
  // (true x) y => x
  // (false x) y => y
  // The machine is strict, so both branches are wrapped in λd. and
  // only the chosen one is applied (to n, any value will do);
  // otherwise f(pred(n)) would recurse forever.
  // H: λf.λn. iszero n (λd.one) (λd.times n (f (pred n))) n
  H = mklam('f', mklam('n',
		       mkapp(mkapp(mkapp(mkapp(iszero, mkid('n')),
					 mklam('d', one)),
				   mklam('d', mkapp(mkapp(times, mkid('n')),
						    mkapp(mkid('f'), mkapp(pred, mkid('n')))))),
			     mkid('n'))));
  fac = mkapp(Z, H);
	
  machine->control = mkapp(succ, mkapp(succ, zero));

  /* dbg(machine); */
  while (machine->control || machine->dump) {
    if (0 != (x = machine->control)) {
      machine->control = machine->control->next;
      if (x->tag == ID) { 				/* case 1a */
	printf("ID\n");
	push(valueof(x->expkind.id, machine->environment), machine);
      } else if (x->tag == LAM) {			/* case 1b */
	printf("LAM\n");
	push(mkclosure(x->expkind.lam.body,
		       x->expkind.lam.bv,
		       machine->environment),
	     machine);
	printf("***\n");
	/* dbg(machine); */
	printf("***\n");
      } else if (x->tag == APP) {			/* case 1c */
	printf("APP\n");
	F = copyexp(x->expkind.app.rator);
	A = copyexp(x->expkind.app.rand);
	printf("F="); print_exp(F); putchar('\n');
	printf("A="); print_exp(A); putchar('\n');
	e = mkat();
	e->next = machine->control;
	F->next = e;
	A->next = F;
	machine->control = A;
      } else if (x->tag == AT) {			/* case 1d */
	f = machine->stack;
	if (!f || !f->next) {
	  fprintf(stderr, "fatal: @ needs a function and an argument on the stack\n");
	  exit(1);
	}
	a = f->next;
	sprim = a->next;
	if (f->tag == PRIM) {			/* case 1di */
	  /* check which primitive function to apply and 
	     replace f and a with f(a) -- implemented later */
	} else if (f->tag == CLOSURE) {		/* case 1dii */
	  V = f->whnfkind.clos.bv;
	  B = f->whnfkind.clos.exp;
	  Eprim = f->whnfkind.clos.envl;
	  MKSTATE(dmp);
	  dmp->stack = sprim;                /* no need to copy */
	  dmp->environment = machine->environment;
	  dmp->control = machine->control;   /* no need to copy */
	  dmp->dump = machine->dump;
	  machine->dump = dmp;
	  machine->stack = NULL;
	  MKENV(ne);
	  ne->name = V;
	  ne->value = copywhnf(a);	/* don't drag the rest of the stack along */
	  ne->next = Eprim;
	  machine->environment = ne;
	  machine->control = B;
	}
      } 
    } else {					/* case 2 */
      machine->stack->next = machine->dump->stack;
      machine->environment = machine->dump->environment;
      machine->control = machine->dump->control;
      machine->dump = machine->dump->dump;
    }
    dbg(machine);
  }
}
