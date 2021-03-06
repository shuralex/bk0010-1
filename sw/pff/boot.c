#include <ansidecl.h>
#include "util.h"
#include "diskio.h"
#include "pff.h"

FATFS fatfs;
DIR dir;
FILINFO fno;

#define SYSREG *((unsigned int*)0177716)    /*!< BK-0010 system control reg */
#define KBSTATE *((unsigned int*)0177660)   /*!< Keyboard status: 0200 == input available */
#define KEYCODE *((unsigned int*)0177662)   /*!< Keyboard keycode */

void xmit() {}  /*!< needed by mmc.c streaming feature, unused */

static char* M_FAIL = "\007:(";   /*!< Failmessage */
static char* M_OK   = "\007:)";     /*!< Winmessage */


static char BKDIR[] = "BK0010";
static char BASIC[] = "M_BASIC.ROM";
static char FOCAL[] = "M_FOCAL.ROM";
static char BINSUFFIX[] = ".BIN";

#define FNBUFL 30                                         /*!< file name buffer size */
char fname[FNBUFL];                                       /*!< file name buffer */

char lastfile[14];              /*!< last valid file for tab completion */

unsigned char buffer[512];      /*!< disk i/o buffer */

unsigned char* romptr = (unsigned char *)0100000; /*!< rom will be read here */

unsigned udummy;
int      idummy;
char*    sdummy;

/*! BIN file header */
struct binhdr {
    unsigned start;             /*!< load location */
    unsigned length;            /*!< file length   */
};

struct emtcb {
    unsigned cmd;
    unsigned start;
    unsigned length;
    char name[20];
} *emtCB;

struct binhdr hdr;


#if DEBUG
#define debug(x)    puts(x)
#else
#define debug(x)    {}
#endif

void newline() { putchar('\n'); }

/**
 * Bootstrap Phase 1. Mount FS, find ROM and open it.
 */
int findrom()
{
    sdummy = BASIC;

    disk_sbuf(buffer);      /* set disk i/o buffer */

    for (idummy = 10000; --idummy > 0 && pf_mount(&fatfs) != FR_OK;);
    if (idummy) {
        strcpy(fname,   BKDIR);
        fname[6] = '/';
        if (!(SYSREG & 0100)) {
            switch (KEYCODE) {
                case 0003:  sdummy = FOCAL;    /* F2/KT   boots FOCAL */
                            break;
                case 0201:
                default:    sdummy = BASIC;    /* F1/POVT boots BASIC */
                            break;
            }
        }
        strcpy(fname+7, sdummy);
        if (pf_open(fname) == FR_OK) {
            return 0;
        }
    }

	return 1;
}

/** 
 * Bootstrap Phase 2. Load the ROM.
 */
int loadrom() {
    return pf_read(romptr, 32752, &idummy) != FR_OK;
}

/**
 * Load bin-file to virtual addresses 0120000-0157777
 */
int loadbin() {
    int n, max;

    /* First pf_open tends to return error for some reason, so two may be necessary.
       If exact filename fails, try appening ".BIN" to its name. */
    for(n = 4; --n > 0 && pf_open(fname) != FR_OK;) {
        if (n == 2) {
            strcpy(fname+strlen(fname), BINSUFFIX);
        }
    }

    hdr.start = 0;

    if (n) {
        if (pf_read(&hdr, sizeof(hdr), &n) == FR_OK) {
            if (emtCB && emtCB->start) hdr.start = emtCB->start;

            max = hdr.length;
            if (hdr.start >= 040000) {
                /* A hack for high-loading programs like MIRAGE */
                romptr = (unsigned char *) (hdr.start + 0120000 - 040000);
                goto readhi;
            } else {
                if (hdr.start + hdr.length > 040000) max -= (hdr.start+hdr.length) - 040000;
            }

            romptr = (unsigned char *) hdr.start + 0120000;

            if (pf_read(romptr, max, &n) == FR_OK) {
                max = hdr.length - max;
                if (max) {
                    romptr = (unsigned char *) 0120000;
readhi:
                    /* map screen area to 12 and read the other part */
                    asm("jsr pc, _umap1");
                    pf_read(romptr, max, &n);
                    /* restore the mapping: emtCB points there */
                    asm("jsr pc, _umap0");
                    return 2;
                }
                return 1;
            }

        }
    }

    return 0;
}

int pace() {
    int c;
    putchar(':'); 
    c = getchar(); 
    putchar(030);

    return c;
}

/** 
 * List all files with names starting with (fname+7).
 * If there is only one matching file, copy its full name into (fname+7).
 */
int listdir() {
    int i, j;

    for(i = 3; --i > 0 && (pf_opndir(&dir, BKDIR)) != FR_OK;);

    if (i) {
        for(i = 0; pf_rddir(&dir, &fno) == FR_OK;) {
            if (!fno.fname[0]) break;
            if (strprefx(fname+7, fno.fname)) {
                if (i == 1) {
                    newline();
                    pputs(lastfile, 16);
                } 
                if (i != 0) pputs(fno.fname, 16);

                if (i == 0) {
                    strcpy(lastfile, fno.fname);
                } else {
                    for (j = 0; lastfile[j] == fno.fname[j]; j++);
                    lastfile[j] = '\0';
                }

                i++;
                if (i == 84) {
                    i -= 80;
                    if (pace() == 0x1b) break;  /* stop on ESC */
                }
            }
        }

        if (i > 0) strcpy(fname+7, lastfile);
        if (i > 1) {
            newline();
        }
        if (emtCB) pace();

        return 0;
    } 

    return -1;
}


/** 
 * ScrollLock and EMT36 entry point.
 *
 * If emtCB is NULL, this is a ScrollLock handler. 
 * Prompt for file name, list directory and load bin file.
 *
 * If emtCB is given, use data from it and skip all interactivity.
 */
int kenter() {
    int c;
    int i;

    fname[7] = 0;

    if (!emtCB) newline();
    for(;;) {
        for (i = 7; fname[i]; i++);

        if (emtCB) {
            for(c = 0; c < 20;) {
                if ((fname[i] = emtCB->name[c++]) == 040) break;
                i++;
            }
            c = 0;
        }
        else {
            puts("\025\032File:"); puts(fname+7);
            for (; i < FNBUFL && ((c = toupper(getchar())) != '\n'); ) {
                if (c == 030) {             /* Backspace/DEL */
                    if (i > 7) { 
                        --i; 
                    } else {
                        continue;
                    }
                } else if (c == 011) {      /* TAB (see below and listdir()) */
                    break;
                } else if (c == 0x1b) {
                    return 0;
                } else {
                    fname[i++] = c;
                }
                putchar(c);
            }
        }

        fname[i] = '\0';

        if (i == 7 || c == 011) {               /* empty file name or tab pressed */
            if((c = listdir()) != 0) {
                puts(M_FAIL);
            }
            if (c||emtCB) return 0;             /* avoid eternal loop if requested name is empty */
        } else {
            if (!emtCB) {
                puts("\nLoading "); puts(fname); 
            }
            c = loadbin();

            if(emtCB) {
                emtCB->cmd = c ? 0 : 0x200;         /* Fill in response: 0 = no error (whatever) */
                *(unsigned *)0120264 = hdr.start;   /* See 00001-01.32.03 page 64: 0264=start, 0266=length */
                *(unsigned *)0120266 = hdr.length;  /* fields of emtCB should be intact */
            } else {
                puts(c ? M_OK : M_FAIL);
                newline();
            }

            return c == 2;
        }
    }
    /* we never make it here */
    /* return 0; */
}
