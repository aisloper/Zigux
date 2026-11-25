# Пересборка ELF: as -o /tmp/userdemo.o userdemo.s && ld -nostdlib -static -e start -Ttext=0x700000000000 -o userdemo.elf /tmp/userdemo.o
.intel_syntax noprefix
.globl start
.text
start:
  # rt_sigaction(SIGUSR1, &act, NULL, 8): SA_SIGINFO handler.
  mov eax, 13
  mov edi, 10
  lea rsi, [rip+act]
  xor edx, edx
  mov r10d, 8
  syscall
  test rax, rax
  js 1f

  # kill(getpid(), SIGUSR1) — доставится перед возвратом из syscall в ring 3.
  mov eax, 39
  syscall
  mov edi, eax
  mov esi, 10
  mov eax, 62
  syscall

  push rax                  # первое обращение к стеку ⇒ demand page fault
  pop rbx
  mov rax, 12               # brk(0) — текущая граница кучи
  xor rdi, rdi
  syscall
  mov r12, rax
  add r12, 4096             # brk(cur + 4096) — выделить страницу
  mov rax, 12
  mov rdi, r12
  syscall
  mov byte ptr [r12-1], 66  # 'B', ещё один demand page fault в anon-VMA кучи
  mov rax, 1                # write(1, heap, 1)
  mov rdi, 1
  mov rsi, r12
  sub rsi, 1
  mov rdx, 1
  syscall
  mov rax, 1                # write(1, "USER!\n", 6)
  mov rdi, 1
  lea rsi, [rip+msg]
  mov rdx, 6
  syscall

  # open("/demo.txt") → mmap(MAP_PRIVATE) → write → munmap → close.
  # Страница file-backed VMA заполняется из struct file при первом #PF.
  mov eax, 2
  lea rdi, [rip+path]
  xor esi, esi
  xor edx, edx
  syscall
  mov r11, rax
  mov eax, 9
  xor edi, edi
  mov esi, 4096
  mov edx, 1
  mov r10d, 2
  mov r8, r11
  xor r9d, r9d
  syscall
  mov r13, rax
  mov al, byte ptr [r13]    # userspace load ⇒ #PF, file-backed fault
  mov eax, 1
  mov edi, 1
  mov rsi, r13
  mov edx, 6
  syscall
  mov eax, 11
  mov rdi, r13
  mov esi, 4096
  syscall
  mov eax, 3
  mov edi, r11d
  syscall

  # Расширенный ABI: lseek + dup + read: namei через VFS, f_pos не сбрасывается
  # при mmap/readAt; dup-дескриптор делит ту же struct file.
  mov eax, 2
  lea rdi, [rip+path]
  xor esi, esi
  xor edx, edx
  syscall
  mov ebp, eax               # исходный fd (r11 портится sysret)
  mov r15, rax
  mov eax, 8                 # lseek(fd, 3, SEEK_SET)
  mov edi, r15d
  mov esi, 3
  xor edx, edx
  syscall
  mov eax, 66                # dup(fd)
  mov edi, r15d
  syscall
  mov r15, rax               # dup-дескриптор
  lea r14, [rsp-16]
  xor eax, eax               # read(dup_fd, buf, 2) → "E!"
  mov edi, r15d
  mov rsi, r14
  mov edx, 2
  syscall
  mov eax, 1
  mov edi, 1
  mov rsi, r14
  mov edx, 2
  syscall
  mov eax, 3
  mov edi, r15d
  syscall
  mov eax, 3
  mov edi, ebp
  syscall

  # fork(): ребёнок получает отдельный PML4; оба процесса пишут в COW-страницу кучи.
  mov eax, 57
  syscall
  test rax, rax
  jz child
  mov byte ptr [r12-1], 80  # parent: 'P', COW fault в родительском PML4
  jmp write_heap
child:
  mov byte ptr [r12-1], 67  # child: 'C', COW fault в дочернем PML4
write_heap:
  mov rax, 1
  mov rdi, 1
  mov rsi, r12
  sub rsi, 1
  mov rdx, 1
  syscall
  mov rax, 60               # exit(0)
  xor rdi, rdi
  syscall
1: jmp 1b

# Обычный SA_SIGINFO-handler: rdi=signo, rsi=&siginfo, rdx=&ucontext.
# ret возвращает на __kernel_rt_sigreturn-трамполин изSigFrame.pretcode.
handler:
  mov eax, 1
  mov edi, 1
  lea rsi, [rip+sigchar]
  mov edx, 1
  syscall
  ret

sigchar: .ascii "S"
act:     .quad handler
         .quad 4             # SA_SIGINFO
         .quad 0             # sa_mask
         .quad 0             # sa_restorer (ядро использует свой trampoline)
msg:     .ascii "USER!\n"
path:    .asciz "/demo.txt"
