/* SPDX-License-Identifier: GPL-2.0 */
/*
 *  linux/arch/x86_64/entry.S
 *
 *  Copyright (C) 1991, 1992  Linus Torvalds
 *  Copyright (C) 2000, 2001, 2002  Andi Kleen SuSE Labs
 *  Copyright (C) 2000  Pavel Machek <pavel@suse.cz>
 *  Copyright (C) 2025  SuperHacker UEFI <zhuoshizhang@hotmail.com>
 *
 * entry.S contains the system-call and fault low-level handling routines.
 *
 * Some of this is documented in Documentation/arch/x86/entry_64.rst
 *
 * A note on terminology:
 * - iret frame:	Architecture defined interrupt frame from SS to RIP
 *			at the top of the kernel process stack.
 *
 * Some macro usage:
 * - SYM_FUNC_START/END:Define functions in the symbol table.
 * - idtentry:		Define exception entry points.
 */
#include <linux/linkage.h>
#include <asm/segment.h>
#include <asm/cache.h>
#include <asm/errno.h>
#include <asm/asm-offsets.h>
#include <asm/msr.h>
#include <asm/unistd.h>
#include <asm/thread_info.h>
#include <asm/hw_irq.h>
#include <asm/page_types.h>
#include <asm/irqflags.h>
#include <asm/paravirt.h>
#include <asm/percpu.h>
#include <asm/asm.h>
#include <asm/smap.h>
#include <asm/pgtable_types.h>
#include <asm/export.h>
#include <asm/frame.h>
#include <asm/trapnr.h>
#include <asm/nospec-branch.h>
#include <asm/fsgsbase.h>
#include <linux/err.h>

#include "calling.h"

.code64
.section .entry.text, "ax"

/*
 * 64-bit SYSCALL instruction entry. Up to 6 arguments in registers.
 *
 * This is the only entry point used for 64-bit system calls.  The
 * hardware interface is reasonably well designed and the register to
 * argument mapping Linux uses fits well with the registers that are
 * available when SYSCALL is used.
 *
 * SYSCALL instructions can be found inlined in libc implementations as
 * well as some other programs and libraries.  There are also a handful
 * of SYSCALL instructions in the vDSO used, for example, as a
 * clock_gettimeofday fallback.
 *
 * 64-bit SYSCALL saves rip to rcx, clears rflags.RF, then saves rflags to r11,
 * then loads new ss, cs, and rip from previously programmed MSRs.
 * rflags gets masked by a value from another MSR (so CLD and CLAC
 * are not needed). SYSCALL does not save anything on the stack
 * and does not change rsp.
 *
 * Registers on entry:
 * rax  system call number
 * rcx  return address
 * r11  saved rflags (note: r11 is callee-clobbered register in C ABI)
 * rdi  arg0
 * rsi  arg1
 * rdx  arg2
 * r10  arg3 (needs to be moved to rcx to conform to C ABI)
 * r8   arg4
 * r9   arg5
 * (note: r12-r15, rbp, rbx are callee-preserved in C ABI)
 *
 * Only called from user space.
 *
 * When user can change pt_regs->foo always force IRET. That is because
 * it deals with uncanonical addresses better. SYSRET has trouble
 * with them due to bugs in both AMD and Intel CPUs.
 */

SYM_CODE_START(entry_SYSCALL_64)
	UNWIND_HINT_ENTRY
	ENDBR

	swapgs
	/* tss.sp2 is scratch space. */
	movq	%rsp, PER_CPU_VAR(cpu_tss_rw + TSS_sp2) // top of the water-Well (shallowest address)?
	SWITCH_TO_KERNEL_CR3 scratch_reg=%rsp
	movq	PER_CPU_VAR(pcpu_hot + X86_top_of_stack), %rsp //Oh, here "top" is means highest address, is actually the deepest of the water-Well (bottom)...

SYM_INNER_LABEL(entry_SYSCALL_64_safe_stack, SYM_L_GLOBAL)
	ANNOTATE_NOENDBR

	/* Construct struct pt_regs on stack */
	pushq	$__USER_DS				/* pt_regs->ss */
	pushq	PER_CPU_VAR(cpu_tss_rw + TSS_sp2)	/* pt_regs->sp */
	pushq	%r11					/* pt_regs->flags */
	pushq	$__USER_CS				/* pt_regs->cs */
	pushq	%rcx					/* pt_regs->ip */
SYM_INNER_LABEL(entry_SYSCALL_64_after_hwframe, SYM_L_GLOBAL)
	pushq	%rax					/* pt_regs->orig_ax */

	PUSH_AND_CLEAR_REGS rax=$-ENOSYS

	/* IRQs are off. */
	movq	%rsp, %rdi
	/* Sign extend the lower 32bit as syscall numbers are treated as int */
	movslq	%eax, %rsi

	/* clobbers %rax, make sure it is after saving the syscall nr */
	IBRS_ENTER
	UNTRAIN_RET

	call	do_syscall_64		/* returns with IRQs disabled */

	// 終わりしよ！
	POP_REGS
	// The stack is now: RAX, RIP, CS, EFLAGS, RSP, SS
	add $8, %rsp // skip RAX
	// Go!
SYM_INNER_LABEL(entry_SYSRETQ_unsafe_stack, SYM_L_GLOBAL)
	ANNOTATE_NOENDBR
	swapgs
	iretq
SYM_INNER_LABEL(entry_SYSRETQ_end, SYM_L_GLOBAL)
	ANNOTATE_NOENDBR
	int3
SYM_CODE_END(entry_SYSCALL_64)

/*
 * %rdi: prev task
 * %rsi: next task
 */
.pushsection .text, "ax"
SYM_FUNC_START(__switch_to_asm)
	/*
	 * Save callee-saved registers
	 * This must match the order in inactive_task_frame
	 */
	pushq	%rbp
	pushq	%rbx
	pushq	%r12
	pushq	%r13
	pushq	%r14
	pushq	%r15

	/* switch stack */
	movq	%rsp, TASK_threadsp(%rdi)
	movq	TASK_threadsp(%rsi), %rsp

#ifdef CONFIG_STACKPROTECTOR
	movq	TASK_stack_canary(%rsi), %rbx
	movq	%rbx, PER_CPU_VAR(fixed_percpu_data) + FIXED_stack_canary
#endif

	/*
	 * When switching from a shallower to a deeper call stack
	 * the RSB may either underflow or use entries populated
	 * with userspace addresses. On CPUs where those concerns
	 * exist, overwrite the RSB with entries which capture
	 * speculative execution to prevent attack.
	 */
	FILL_RETURN_BUFFER %r12, RSB_CLEAR_LOOPS, X86_FEATURE_RSB_CTXSW

	/* restore callee-saved registers */
	popq	%r15
	popq	%r14
	popq	%r13
	popq	%r12
	popq	%rbx
	popq	%rbp

	jmp	__switch_to
SYM_FUNC_END(__switch_to_asm)
.popsection

/*
 * A newly forked process directly context switches into this address.
 *
 * rax: prev task we switched from
 * rbx: kernel thread func (NULL for user thread)
 * r12: kernel thread arg
 */
.pushsection .text, "ax"
SYM_CODE_START(ret_from_fork_asm)
	/*
	 * This is the start of the kernel stack; even through there's a
	 * register set at the top, the regset isn't necessarily coherent
	 * (consider kthreads) and one cannot unwind further.
	 *
	 * This ensures stack unwinds of kernel threads terminate in a known
	 * good state.
	 */
	UNWIND_HINT_END_OF_STACK
	ANNOTATE_NOENDBR // copy_thread
	CALL_DEPTH_ACCOUNT

	movq	%rax, %rdi		/* prev */
	movq	%rsp, %rsi		/* regs */
	movq	%rbx, %rdx		/* fn */
	movq	%r12, %rcx		/* fn_arg */
	call	ret_from_fork

	/*
	 * Set the stack state to what is expected for the target function
	 * -- at this point the register set should be a valid user set
	 * and unwind should work normally.
	 */
	UNWIND_HINT_REGS
	jmp	swapgs_restore_regs_and_return_to_usermode
SYM_CODE_END(ret_from_fork_asm)
.popsection

.macro DEBUG_ENTRY_ASSERT_IRQS_OFF
#ifdef CONFIG_DEBUG_ENTRY
	pushq %rax
	SAVE_FLAGS
	testl $X86_EFLAGS_IF, %eax
	jz .Lokay_\@
	ud2
.Lokay_\@:
	popq %rax
#endif
.endm

/**
 * idtentry_body - Macro to emit code calling the C function
 * @cfunc:		C function to be called
 * @has_error_code:	Hardware pushed error code on stack
 */
.macro idtentry_body cfunc has_error_code:req
	// Don't call the fucking error_entry!
	PUSH_AND_CLEAR_REGS save_ret=0 // Fucking save_ret eating the stack!

	ENCODE_FRAME_POINTER
	UNWIND_HINT_REGS

	movq	%rsp, %rdi			/* pt_regs pointer into 1st argument*/

	.if \has_error_code == 1
		movq	ORIG_RAX(%rsp), %rsi	/* get error code into 2nd argument*/
		movq	$-1, ORIG_RAX(%rsp)	/* no syscall to restart */
	.endif

	call	\cfunc

	/* For some configurations \cfunc ends up being a noreturn. */
	REACHABLE

	jmp	error_return
.endm

.macro chk_swap_gs_rsp has_error_code magicDbg
	.if \has_error_code == 1 // Exception
		.if \magicDbg == 1
			// make a debug signal to QEMU
			push %dx
			push %ax
			push %bx
			mov $0x2333, %dx // destination port
			mov $0xE399, %ax // dump stack command
			mov $(6+48), %bx // dump length
			out %ax, %dx
			pop %bx
			pop %ax
			pop %dx
		.endif
		
		push %rax // backup rax
		mov %rsp, %rax // let RAX hold current stack :)
		/* RAX Layout
		RAX+0: RAX we just backed up
		RAX+8: error code
		RAX+16: orignal RIP
		RAX+24: orignal CS
		RAX+32: orignal RFLAGS
		RAX+40: orignal RSP
		RAX+48: orignal SS
		*/
		cmp $__KERNEL_CS, 24(%rax)
		je _act_ker\@
		// 23333 section, we are from user space
		swapgs
		movq	PER_CPU_VAR(pcpu_hot + X86_top_of_stack), %rsp // let's go to user-kernel-stack
		jmp _cp_stack\@
		// 23333 section
		_act_ker\@:
		movq 40(%rax), %rsp // set rsp to the orignal
		andq $~0xff, %rsp // align to 256 bytes
		_cp_stack\@:
		pushq 48(%rax) // push "orignal SS"
		pushq 40(%rax) // push "orignal RSP"
		pushq 32(%rax) // push "orignal RFLAGS"
		pushq 24(%rax) // push "orignal CS"
		pushq 16(%rax) // push "orignal RIP"
		pushq 8(%rax) // push error code
		movq 0(%rax), %rax // restore rax
		
		.if \magicDbg == 1
			// make a debug signal to QEMU
			push %dx
			push %ax
			push %bx
			mov $0x2333, %dx // destination port
			mov $0xE399, %ax // dump stack command
			mov $(6+48), %bx // dump length
			out %ax, %dx
			pop %bx
			pop %ax
			pop %dx
		.endif
	.else // Interrupt
		.if \magicDbg == 1
			// make a debug signal to QEMU
			push %dx
			push %ax
			push %bx
			mov $0x2333, %dx // destination port
			mov $0xE399, %ax // dump stack command
			mov $(6+40), %bx // dump length
			out %ax, %dx
			pop %bx
			pop %ax
			pop %dx
		.endif

		push %rax // backup rax
		movq %rsp, %rax // let RAX hold current stack :)S
		/* RAX Layout
		RAX+0: RAX we just backed up
		RAX+8: orignal RIP
		RAX+16: orignal CS
		RAX+24: orignal RFLAGS
		RAX+32: orignal RSP
		RAX+40: orignal SS
		*/
		cmp $__KERNEL_CS, 16(%rax)
		je _act_ker\@
		// 23333 section, we are from user space
		swapgs
		movq	PER_CPU_VAR(pcpu_hot + X86_top_of_stack), %rsp // let's go to user-kernel-stack
		jmp _cp_stack\@
		// 23333 section
		_act_ker\@:
		movq 32(%rax), %rsp // set rsp to the orignal
		andq $~0xff, %rsp // align to 256 bytes
		_cp_stack\@:
		pushq 40(%rax) // push "orignal SS"
		pushq 32(%rax) // push "orignal RSP"
		pushq 24(%rax) // push "orignal RFLAGS"
		pushq 16(%rax) // push "orignal CS"
		pushq 8(%rax) // push "orignal RIP"
		movq 0(%rax), %rax // restore rax

		.if \magicDbg == 1
			// make a debug signal to QEMU
			push %dx
			push %ax
			push %bx
			mov $0x2333, %dx // destination port
			mov $0xE399, %ax // dump stack command
			mov $(6+40), %bx // dump length
			out %ax, %dx
			pop %bx
			pop %ax
			pop %dx
		.endif
	.endif
.endm

/**
 * idtentry - Macro to generate entry stubs for simple IDT entries
 * @vector:		Vector number
 * @asmsym:		ASM symbol for the entry point
 * @cfunc:		C function to be called
 * @has_error_code:	Hardware pushed error code on stack
 *
 * The macro emits code to set up the kernel context for straight forward
 * and simple IDT entries. No IST stack, no paranoid entry checks.
 */
.macro idtentry vector asmsym cfunc has_error_code:req
SYM_CODE_START(\asmsym)
	// we should revert to the original RSP if interrupt/excption is from kernel space
	chk_swap_gs_rsp \has_error_code 0

	.if \vector == X86_TRAP_BP
		/* #BP advances %rip to the next instruction */
		UNWIND_HINT_IRET_ENTRY offset=\has_error_code*8 signal=0
	.else
		UNWIND_HINT_IRET_ENTRY offset=\has_error_code*8
	.endif

	ENDBR
	ASM_CLAC
	cld

	.if \has_error_code == 0
		pushq	$-1			/* ORIG_RAX: no syscall to restart */
	.endif

	.if \vector == X86_TRAP_BP
		/*
		 * If coming from kernel space, create a 6-word gap to allow the
		 * int3 handler to emulate a call instruction.
		 */
		cmp	$__KERNEL_CS, CS-ORIG_RAX(%rsp)
		jne	.Lfrom_usermode_no_gap_\@
		.rept	6
		pushq	5*8(%rsp)
		.endr
		UNWIND_HINT_IRET_REGS offset=8
.Lfrom_usermode_no_gap_\@:
	.endif

	idtentry_body \cfunc \has_error_code

_ASM_NOKPROBE(\asmsym)
SYM_CODE_END(\asmsym)
.endm

/*
 * Double fault entry. Straight paranoid. No checks from which context
 * this comes because for the espfix induced #DF this would do the wrong
 * thing.
 	RSP+0: error code
	RSP+8: orignal RIP
	RSP+16: orignal CS
	RSP+24: orignal RFLAGS
	RSP+32: orignal RSP
	RSP+40: orignal SS
 */

.macro idtentry_df vector asmsym cfunc
SYM_CODE_START(\asmsym)
	UNWIND_HINT_IRET_ENTRY offset=8
	// make a debug signal to QEMU
	mov $0x2333, %dx // destination port
	mov $0xDEAD, %ax // data
	out %ax, %dx
	// adjust gs
	cmp $__KERNEL_CS, 16(%rsp)
	je already_ker_gs
	// 2333, we are from user thread
	swapgs
already_ker_gs:
	idtentry_body \cfunc has_error_code=1
SYM_CODE_END(\asmsym)
.endm

/*
 * Include the defines which emit the idt entries which are shared
 * shared between 32 and 64 bit and emit the __irqentry_text_* markers
 * so the stacktrace boundary checks work.
 */
	__ALIGN
	.globl __irqentry_text_start
__irqentry_text_start:

#include <asm/idtentry.h>

	__ALIGN
	.globl __irqentry_text_end
__irqentry_text_end:
	ANNOTATE_NOENDBR

SYM_CODE_START_LOCAL(common_interrupt_return)
SYM_INNER_LABEL(swapgs_restore_regs_and_return_to_usermode, SYM_L_GLOBAL)
	IBRS_EXIT

	POP_REGS
	// The stack is now: RAX, RIP, CS, EFLAGS, RSP, SS
	add $8, %rsp // skip RAX
	// Go!
	swapgs
	iretq

SYM_INNER_LABEL(restore_regs_and_return_to_kernel, SYM_L_GLOBAL)
	POP_REGS
	addq	$8, %rsp	/* skip regs->orig_ax */
	/*
	 * ARCH_HAS_MEMBARRIER_SYNC_CORE rely on IRET core serialization
	 * when returning from IPI handler.
	 */

.Lnative_iret:
	UNWIND_HINT_IRET_REGS
	/*
	 * Are we returning to a stack segment from the LDT?  Note: in
	 * 64-bit mode SS:RSP on the exception stack is always valid.
	 */
#ifdef CONFIG_X86_ESPFIX64
	testb	$4, (SS-RIP)(%rsp)
	jnz	native_irq_return_ldt
#endif

SYM_INNER_LABEL(native_irq_return_iret, SYM_L_GLOBAL)
	ANNOTATE_NOENDBR // exc_double_fault
	/*
	 * This may fault.  Non-paranoid faults on return to userspace are
	 * handled by fixup_bad_iret.  These include #SS, #GP, and #NP.
	 * Double-faults due to espfix64 are handled in exc_double_fault.
	 * Other faults here are fatal.
	 */
	iretq

#ifdef CONFIG_X86_ESPFIX64
native_irq_return_ldt:
	/*
	 * We are running with user GSBASE.  All GPRs contain their user
	 * values.  We have a percpu ESPFIX stack that is eight slots
	 * long (see ESPFIX_STACK_SIZE).  espfix_waddr points to the bottom
	 * of the ESPFIX stack.
	 *
	 * We clobber RAX and RDI in this code.  We stash RDI on the
	 * normal stack and RAX on the ESPFIX stack.
	 *
	 * The ESPFIX stack layout we set up looks like this:
	 *
	 * --- top of ESPFIX stack ---
	 * SS
	 * RSP
	 * RFLAGS
	 * CS
	 * RIP  <-- RSP points here when we're done
	 * RAX  <-- espfix_waddr points here
	 * --- bottom of ESPFIX stack ---
	 */

	pushq	%rdi				/* Stash user RDI */
	swapgs					/* to kernel GS */
	SWITCH_TO_KERNEL_CR3 scratch_reg=%rdi	/* to kernel CR3 */

	movq	PER_CPU_VAR(espfix_waddr), %rdi
	movq	%rax, (0*8)(%rdi)		/* user RAX */
	movq	(1*8)(%rsp), %rax		/* user RIP */
	movq	%rax, (1*8)(%rdi)
	movq	(2*8)(%rsp), %rax		/* user CS */
	movq	%rax, (2*8)(%rdi)
	movq	(3*8)(%rsp), %rax		/* user RFLAGS */
	movq	%rax, (3*8)(%rdi)
	movq	(5*8)(%rsp), %rax		/* user SS */
	movq	%rax, (5*8)(%rdi)
	movq	(4*8)(%rsp), %rax		/* user RSP */
	movq	%rax, (4*8)(%rdi)
	/* Now RAX == RSP. */

	andl	$0xffff0000, %eax		/* RAX = (RSP & 0xffff0000) */

	/*
	 * espfix_stack[31:16] == 0.  The page tables are set up such that
	 * (espfix_stack | (X & 0xffff0000)) points to a read-only alias of
	 * espfix_waddr for any X.  That is, there are 65536 RO aliases of
	 * the same page.  Set up RSP so that RSP[31:16] contains the
	 * respective 16 bits of the /userspace/ RSP and RSP nonetheless
	 * still points to an RO alias of the ESPFIX stack.
	 */
	orq	PER_CPU_VAR(espfix_stack), %rax

	swapgs					/* to user GS */
	popq	%rdi				/* Restore user RDI */

	movq	%rax, %rsp
	UNWIND_HINT_IRET_REGS offset=8

	/*
	 * At this point, we cannot write to the stack any more, but we can
	 * still read.
	 */
	popq	%rax				/* Restore user RAX */

	/*
	 * RSP now points to an ordinary IRET frame, except that the page
	 * is read-only and RSP[31:16] are preloaded with the userspace
	 * values.  We can now IRET back to userspace.
	 */
	jmp	native_irq_return_iret
#endif
SYM_CODE_END(common_interrupt_return)
_ASM_NOKPROBE(common_interrupt_return)

/*
 * Reload gs selector with exception handling
 *  di:  new selector
 *
 * Is in entry.text as it shouldn't be instrumented.
 */
SYM_FUNC_START(asm_load_gs_index)
	FRAME_BEGIN
	swapgs
.Lgs_change:
	ANNOTATE_NOENDBR // error_entry
	movl	%edi, %gs
2:	ALTERNATIVE "", "mfence", X86_BUG_SWAPGS_FENCE
	swapgs
	FRAME_END
	RET

	/* running with kernelgs */
.Lbad_gs:
	swapgs					/* switch back to user gs */
.macro ZAP_GS
	/* This can't be a string because the preprocessor needs to see it. */
	movl $__USER_DS, %eax
	movl %eax, %gs
.endm
	ALTERNATIVE "", "ZAP_GS", X86_BUG_NULL_SEG
	xorl	%eax, %eax
	movl	%eax, %gs
	jmp	2b

	_ASM_EXTABLE(.Lgs_change, .Lbad_gs)

SYM_FUNC_END(asm_load_gs_index)
EXPORT_SYMBOL(asm_load_gs_index)

#ifdef CONFIG_XEN_PV
/*
 * A note on the "critical region" in our callback handler.
 * We want to avoid stacking callback handlers due to events occurring
 * during handling of the last event. To do this, we keep events disabled
 * until we've done all processing. HOWEVER, we must enable events before
 * popping the stack frame (can't be done atomically) and so it would still
 * be possible to get enough handler activations to overflow the stack.
 * Although unlikely, bugs of that kind are hard to track down, so we'd
 * like to avoid the possibility.
 * So, on entry to the handler we detect whether we interrupted an
 * existing activation in its critical region -- if so, we pop the current
 * activation and restart the handler using the previous one.
 *
 * C calling convention: exc_xen_hypervisor_callback(struct *pt_regs)
 */
	__FUNC_ALIGN
SYM_CODE_START_LOCAL_NOALIGN(exc_xen_hypervisor_callback)

/*
 * Since we don't modify %rdi, evtchn_do_upall(struct *pt_regs) will
 * see the correct pointer to the pt_regs
 */
	UNWIND_HINT_FUNC
	movq	%rdi, %rsp			/* we don't return, adjust the stack frame */
	UNWIND_HINT_REGS

	call	xen_pv_evtchn_do_upcall

	jmp	error_return
SYM_CODE_END(exc_xen_hypervisor_callback)

/*
 * Hypervisor uses this for application faults while it executes.
 * We get here for two reasons:
 *  1. Fault while reloading DS, ES, FS or GS
 *  2. Fault while executing IRET
 * Category 1 we do not need to fix up as Xen has already reloaded all segment
 * registers that could be reloaded and zeroed the others.
 * Category 2 we fix up by killing the current process. We cannot use the
 * normal Linux return path in this case because if we use the IRET hypercall
 * to pop the stack frame we end up in an infinite loop of failsafe callbacks.
 * We distinguish between categories by comparing each saved segment register
 * with its current contents: any discrepancy means we in category 1.
 */
	__FUNC_ALIGN
SYM_CODE_START_NOALIGN(xen_failsafe_callback)
	UNWIND_HINT_UNDEFINED
	ENDBR
	movl	%ds, %ecx
	cmpw	%cx, 0x10(%rsp)
	jne	1f
	movl	%es, %ecx
	cmpw	%cx, 0x18(%rsp)
	jne	1f
	movl	%fs, %ecx
	cmpw	%cx, 0x20(%rsp)
	jne	1f
	movl	%gs, %ecx
	cmpw	%cx, 0x28(%rsp)
	jne	1f
	/* All segments match their saved values => Category 2 (Bad IRET). */
	movq	(%rsp), %rcx
	movq	8(%rsp), %r11
	addq	$0x30, %rsp
	pushq	$0				/* RIP */
	UNWIND_HINT_IRET_REGS offset=8
	jmp	asm_exc_general_protection
1:	/* Segment mismatch => Category 1 (Bad segment). Retry the IRET. */
	movq	(%rsp), %rcx
	movq	8(%rsp), %r11
	addq	$0x30, %rsp
	UNWIND_HINT_IRET_REGS
	pushq	$-1 /* orig_ax = -1 => not a system call */
	PUSH_AND_CLEAR_REGS
	ENCODE_FRAME_POINTER
	jmp	error_return
SYM_CODE_END(xen_failsafe_callback)
#endif /* CONFIG_XEN_PV */

SYM_CODE_START_LOCAL(error_return)
	UNWIND_HINT_REGS
	DEBUG_ENTRY_ASSERT_IRQS_OFF
	cmp	$__KERNEL_CS, CS(%rsp)
	je	restore_regs_and_return_to_kernel
	jmp	swapgs_restore_regs_and_return_to_usermode
SYM_CODE_END(error_return)

#ifndef CONFIG_IA32_EMULATION
/*
 * This handles SYSCALL from 32-bit code.  There is no way to program
 * MSRs to fully disable 32-bit SYSCALL.
 */
SYM_CODE_START(ignore_sysret)
	UNWIND_HINT_END_OF_STACK
	ENDBR
	mov	$-ENOSYS, %eax
	sysretl
SYM_CODE_END(ignore_sysret)
#endif

.pushsection .text, "ax"
	__FUNC_ALIGN
SYM_CODE_START_NOALIGN(rewind_stack_and_make_dead)
	UNWIND_HINT_FUNC
	/* Prevent any naive code from trying to unwind to our caller. */
	xorl	%ebp, %ebp

	movq	PER_CPU_VAR(pcpu_hot + X86_top_of_stack), %rax
	leaq	-PTREGS_SIZE(%rax), %rsp
	UNWIND_HINT_REGS

	call	make_task_dead
SYM_CODE_END(rewind_stack_and_make_dead)
.popsection