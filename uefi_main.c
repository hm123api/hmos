/* HMOS UEFI BOOTX64.EFI - self-contained, no gnu-efi static lib.
 * Built with clang + lld-link into a standard PE32+ EFI application.
 */
#include <stdint.h>

typedef uint64_t UINTN;
typedef uint64_t UINT64;
typedef uint32_t UINT32;
typedef uint16_t CHAR16;
typedef uint8_t  BOOLEAN;
typedef void     VOID;

typedef VOID *EFI_HANDLE;
typedef UINTN EFI_STATUS;

typedef struct _EFI_SIMPLE_TEXT_OUTPUT_PROTOCOL EFI_SIMPLE_TEXT_OUTPUT_PROTOCOL;

typedef EFI_STATUS (__attribute__((ms_abi)) *TEXT_RESET)(
    EFI_SIMPLE_TEXT_OUTPUT_PROTOCOL *This, BOOLEAN ExtendedVerification);
typedef EFI_STATUS (__attribute__((ms_abi)) *TEXT_OUT_STRING)(
    EFI_SIMPLE_TEXT_OUTPUT_PROTOCOL *This, CHAR16 *String);
typedef EFI_STATUS (__attribute__((ms_abi)) *TEXT_CLEAR_SCREEN)(
    EFI_SIMPLE_TEXT_OUTPUT_PROTOCOL *This);

struct _EFI_SIMPLE_TEXT_OUTPUT_PROTOCOL {
    TEXT_RESET            Reset;            // 0x00
    TEXT_OUT_STRING       OutputString;     // 0x08
    VOID                 *TestString;        // 0x10
    VOID                 *QueryMode;        // 0x18
    VOID                 *SetMode;           // 0x20
    VOID                 *SetAttribute;      // 0x28
    TEXT_CLEAR_SCREEN     ClearScreen;       // 0x30
    VOID                 *SetCursorPosition; // 0x38
    VOID                 *EnableCursor;       // 0x40
};

/* EFI_TABLE_HEADER: Signature(u64) Revision(u32) HeaderSize(u32) CRC32(u32) Reserved(u32) = 24 bytes */
typedef struct {
    UINT64 Signature;
    UINT32 Revision;
    UINT32 HeaderSize;
    UINT32 CRC32;
    UINT32 Reserved;
} EFI_TABLE_HEADER;

typedef struct {
    EFI_TABLE_HEADER                 Hdr;                 // 0x00, 24 bytes
    CHAR16                          *FirmwareVendor;      // 0x18
    UINT32                           FirmwareRevision;    // 0x20
    EFI_HANDLE                       ConsoleInHandle;     // 0x28
    VOID                            *ConIn;               // 0x30
    EFI_HANDLE                       ConsoleOutHandle;     // 0x38
    EFI_SIMPLE_TEXT_OUTPUT_PROTOCOL *ConOut;              // 0x40
    EFI_HANDLE                       StandardErrorHandle;  // 0x48
    VOID                            *StdErr;              // 0x50
    VOID                            *RuntimeServices;      // 0x58
    VOID                            *BootServices;        // 0x60
    UINTN                            NumberOfTableEntries; // 0x68
    VOID                            *ConfigurationTable;   // 0x70
} EFI_SYSTEM_TABLE;

#define EFIAPI __attribute__((ms_abi))
#define EFI_SUCCESS 0

static const CHAR16 message[] = {
    'H','M','O','S',' ','-',' ','U','E','F','I',' ','B','o','o','t',' ','O','K','!','\r','\n',0
};

EFI_STATUS EFIAPI efi_main(EFI_HANDLE ImageHandle, EFI_SYSTEM_TABLE *SystemTable)
{
    (void)ImageHandle;
    if (SystemTable == 0 || SystemTable->ConOut == 0) {
        for (;;) { }
    }
    EFI_SIMPLE_TEXT_OUTPUT_PROTOCOL *out = SystemTable->ConOut;
    out->Reset(out, 0);
    out->ClearScreen(out);
    out->OutputString(out, (CHAR16 *)message);
    for (;;) { }
    return EFI_SUCCESS;
}
