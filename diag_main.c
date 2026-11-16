/* Diag EFI: dump Secure Boot related UEFI variables to ConOut.
 * Built plain (unsigned) so it loads under a non-secure / setup-mode firmware.
 */
#include <stdint.h>

typedef uint64_t UINTN;
typedef uint64_t UINT64;
typedef uint32_t UINT32;
typedef uint16_t CHAR16;
typedef uint8_t  UINT8;
typedef uint8_t  BOOLEAN;
typedef void     VOID;
typedef VOID *EFI_HANDLE;
typedef UINTN EFI_STATUS;

typedef struct _EFI_SIMPLE_TEXT_OUTPUT_PROTOCOL EFI_SIMPLE_TEXT_OUTPUT_PROTOCOL;
typedef EFI_STATUS (__attribute__((ms_abi)) *TEXT_RESET)(EFI_SIMPLE_TEXT_OUTPUT_PROTOCOL*, BOOLEAN);
typedef EFI_STATUS (__attribute__((ms_abi)) *TEXT_OUT_STRING)(EFI_SIMPLE_TEXT_OUTPUT_PROTOCOL*, CHAR16*);
typedef EFI_STATUS (__attribute__((ms_abi)) *TEXT_CLEAR_SCREEN)(EFI_SIMPLE_TEXT_OUTPUT_PROTOCOL*);
struct _EFI_SIMPLE_TEXT_OUTPUT_PROTOCOL {
    TEXT_RESET Reset; TEXT_OUT_STRING OutputString; VOID* TestString; VOID* QueryMode; VOID* SetMode;
    VOID* SetAttribute; TEXT_CLEAR_SCREEN ClearScreen; VOID* SetCursorPosition; VOID* EnableCursor;
};

typedef struct { UINT64 Signature; UINT32 Revision; UINT32 HeaderSize; UINT32 CRC32; UINT32 Reserved; } EFI_TABLE_HEADER;

/* RuntimeServices GetVariable: offset 0x58 in RS table; GetVariable is RS offset 0x68 */
typedef EFI_STATUS (__attribute__((ms_abi)) *GET_VARIABLE)(
    CHAR16 *Name, VOID *VendorGuid, UINT32 *Attributes, UINTN *DataSize, VOID *Data);

typedef struct {
    EFI_TABLE_HEADER Hdr;
    /* Time services (RS 0x18..0x38) */
    VOID *GetTime; VOID *SetTime; VOID *GetWakeupTime; VOID *SetWakeupTime;
    VOID *SetVirtualAddressMap; VOID *ConvertPointer;
    /* Variable services: GetVariable at RS offset 0x68 */
    VOID *GetVariable;          // 0x68
    VOID *GetNextVariableName; // 0x70
    VOID *SetVariable;         // 0x78
    VOID *GetNextHighMonotonicCount; // 0x80
} EFI_RUNTIME_SERVICES;

typedef struct {
    EFI_TABLE_HEADER Hdr;
    CHAR16 *FirmwareVendor; UINT32 FirmwareRevision;
    EFI_HANDLE ConsoleInHandle; VOID *ConIn;
    EFI_HANDLE ConsoleOutHandle; EFI_SIMPLE_TEXT_OUTPUT_PROTOCOL *ConOut;
    EFI_HANDLE StandardErrorHandle; VOID *StdErr;
    EFI_RUNTIME_SERVICES *RuntimeServices; VOID *BootServices;
    UINTN NumberOfTableEntries; VOID *ConfigurationTable;
} EFI_SYSTEM_TABLE;

#define EFIAPI __attribute__((ms_abi))
#define EFI_SUCCESS 0
#define EFI_BUFFER_TOO_SMALL 5

static EFI_SIMPLE_TEXT_OUTPUT_PROTOCOL *gOut;

static void puts(CHAR16 *s) { gOut->OutputString(gOut, s); }

static void u16(CHAR16 *buf, UINTN n, UINT32 v) {
    static const CHAR16 hex[] = L"0123456789ABCDEF";
    for (int i = 7; i >= 0; i--) { buf[n++] = hex[(v >> (i*4)) & 0xF]; }
    buf[n] = 0;
}

static void dump_var(CHAR16 *name, UINT8 *guid, EFI_RUNTIME_SERVICES *rs) {
    CHAR16 line[160];
    GET_VARIABLE GetVar = (GET_VARIABLE)rs->GetVariable;
    UINTN size = 0; UINT32 attr = 0;
    EFI_STATUS st = GetVar(name, guid, &attr, &size, 0);
    if (st != EFI_BUFFER_TOO_SMALL) {
        static const CHAR16 nv[] = L"  <not present>\r\n";
        line[0] = 0;
        /* build name + not present */
        puts(name); puts((CHAR16*)nv);
        return;
    }
    UINT8 data[1024];
    if (size > sizeof(data)) size = sizeof(data);
    st = GetVar(name, guid, &attr, &size, data);
    if (st != EFI_SUCCESS) { puts(L"  <read fail>\r\n"); return; }
    puts(name); puts(L" size=");
    /* print size decimal via hex-ish */
    u16(line, 0, (UINT32)size); puts(line);
    puts(L" attr="); u16(line, 0, attr); puts(line);
    puts(L" head=");
    for (UINTN i = 0; i < size && i < 16; i++) {
        u16(line, 0, data[i]); puts(line); puts(L" ");
    }
    puts(L"\r\n");
}

static const UINT8 GLOBAL_GUID[16] = {0x8c,0xdf,0xe4,0x8b,0xca,0x93,0xd2,0x11,0xaa,0x0d,0x00,0xe0,0x98,0x03,0x2b,0x8c};
static const UINT8 IMG_SEC_GUID[16] = {0xcb,0xb2,0x19,0xd7,0x3a,0x3d,0x96,0x45,0xa3,0xbc,0xda,0xd0,0x0e,0x67,0x65,0x6f};

EFI_STATUS EFIAPI efi_main(EFI_HANDLE ImageHandle, EFI_SYSTEM_TABLE *SystemTable) {
    (void)ImageHandle;
    if (!SystemTable || !SystemTable->ConOut) { for(;;){} }
    gOut = SystemTable->ConOut;
    gOut->Reset(gOut, 0); gOut->ClearScreen(gOut);
    EFI_RUNTIME_SERVICES *rs = SystemTable->RuntimeServices;
    puts(L"=== HMOS SB DIAG ===\r\n");
    dump_var(L"SecureBoot", GLOBAL_GUID, rs);
    dump_var(L"SetupMode", GLOBAL_GUID, rs);
    dump_var(L"SecureBootEnable", GLOBAL_GUID, rs);
    dump_var(L"PK", GLOBAL_GUID, rs);
    dump_var(L"KEK", GLOBAL_GUID, rs);
    dump_var(L"db", IMG_SEC_GUID, rs);
    dump_var(L"dbx", IMG_SEC_GUID, rs);
    for(;;){}
    return EFI_SUCCESS;
}
