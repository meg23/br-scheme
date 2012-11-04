#>

/*
 *
 * br (BottleRocket)
 *
 * Control software for the X10(R) FireCracker wireless computer
 * interface kit.
 *
 * (c) 1999 Ashley Clark (aclark@ghoti.org) and Tymm Twillman (tymm@acm.org)
 *  Free Software.  LGPL applies.
 *  No warranties expressed or implied.
 *
 * Have fun with it and if you do anything really cool, send an email and let us
 * know.
 *
 */

#include <unistd.h>
#include <sys/ioctl.h>
#include <stdio.h>
#include <fcntl.h>
#include <sys/types.h>
#include <sys/time.h>
#include <limits.h>
#include <stdlib.h>
#include <ctype.h>
#include <string.h>
#include <getopt.h>
#include <errno.h>
#include <termios.h>
#include <sys/termios.h>
#include <features.h>
#include <errno.h>

#define VERSION "0.04c"
#define MAX_CMD     7
#define MAX_housecode  15
#define MAX_DEVICE 15
#define HAVE_GETOPT_LONG 1
#define HAVE_ERRNO_H 1
#define HAVE_FEATURES_H 1
#define HAVE_SYS_TERMIOS_H 1
#define HAVE_TERMIOS_H 1
#define DIMRANGE 12
#define MAX_COMMANDS 512
#define HOUSENAME(house) (((house < 0) || (house > 15)) ? \
                          '?':"ABCDEFGHIJKLMNOP"[house])
#define DEVNAME(dev) (((dev < 0) || (dev > 16)) ? 0 : dev + 1)
#define CINFO_CLR(cinfo) memset(cinfo, 0, sizeof(br_control_info))
#define SAFE_FILENO(fd) ((fd != STDIN_FILENO) && (fd != STDOUT_FILENO) \
                        && (fd != STDERR_FILENO))

#ifndef X10_BR_CMD_H
  #define X10_BR_CMD_H
  #define ON 0
  #define OFF 1
  #define DIM 2
  #define BRIGHT 3 /* upper bit gets masked off; just to tell dim/bright apart */
  #define ALL_OFF 4
  #define ALL_ON 5
  #define ALL_LAMPS_OFF 6
  #define ALL_LAMPS_ON 7
  int x10_br_out(int, unsigned char, int);
  extern int PreCmdDelay;
  extern int PostCmdDelay;
  extern int InterBitDelay;
#endif

#ifdef HAVE_ISSETUGID
  #define ISSETID() (issetugid())
#else
  #define ISSETID() (getuid() != geteuid() || getgid() != getegid())
#endif

#ifndef TIOCM_FOR_0
  #define TIOCM_FOR_0 TIOCM_DTR
#endif

#ifndef TIOCM_FOR_1
  #define TIOCM_FOR_1 TIOCM_RTS
#endif

int VERBOSE = 1;
char *X10_PORTNAME = '\0';

int PreCmdDelay = 300000;   
int PostCmdDelay = 300000;
int InterBitDelay = 1400;

static char housecode_table[] = {
  /* A */ 0x06, /* B */ 0x07, /* C */ 0x04, /* D */ 0x05,
  /* E */ 0x08, /* F */ 0x09, /* G */ 0x0a, /* H */ 0x0b,
  /* I */ 0x0e, /* J */ 0x0f, /* K */ 0x0c, /* L */ 0x0d,
  /* M */ 0x00, /* N */ 0x01, /* O */ 0x02, /* P */ 0x03
};

static char device_table[][2] = {
/*   1-4 */ {0x00, 0x00}, {0x00, 0x10}, {0x00, 0x08}, {0x00, 0x18},
/*   5-8 */ {0x00, 0x40}, {0x00, 0x50}, {0x00, 0x48}, {0x00, 0x58},
/*  9-12 */ {0x04, 0x00}, {0x04, 0x10}, {0x04, 0x08}, {0x04, 0x18},
/* 13-16 */ {0x04, 0x40}, {0x04, 0x50}, {0x04, 0x48}, {0x04, 0x58}
};

 static char cmd_table[] = {
/* off */       0x00, /* on */       0x20,
/* dim */       0x98, /* bright */   0x88,
/* all off */   0x80, /* all on */   0x91, 
/* lamps off */ 0x84, /* lamps on */ 0x94
};

static int usec_sleep(long usecs)
{
    struct timeval sleeptime;
    int tmperrno;

    sleeptime.tv_sec = usecs / 1000000;
    sleeptime.tv_usec = usecs % 1000000;

    if (select(0, NULL, NULL, NULL, &sleeptime) < 0) {
	tmperrno = errno;
	perror("select");
	errno = tmperrno;
        return -1;
    }

    return 0;
}

static int usec_delay(long usecs)
{
    struct timeval endtime;
    struct timeval currtime;
    int tmperrno;

    if (gettimeofday(&endtime, NULL) < 0) {
        tmperrno = errno;
        perror("gettimeofday");
        errno = tmperrno;
        return -1;
    }

    endtime.tv_usec += usecs;

    if (endtime.tv_usec > 1000000) {
        endtime.tv_sec++;
        endtime.tv_usec -= 1000000;
    }

    do {
        if (gettimeofday(&currtime, NULL) < 0) {
            tmperrno = errno;
            perror("gettimeofday");
            errno = tmperrno;
            return -1;
        }
    } while (timercmp(&endtime, &currtime, >));

    return 0;
}

static int bits_out(const int fd, const int bits)
{
    int out;
    int tmperrno;

    out = (bits) ? TIOCM_FOR_0:TIOCM_FOR_1;

    if (ioctl(fd, TIOCMBIC, &out) < 0) {
        tmperrno = errno;
        perror("ioctl");
        errno = tmperrno;
        return -1;
    }

    if (usec_delay(InterBitDelay) < 0)
        return -1;
    
    return 0;
}

static int clock_out(const int fd)
{
    int out = TIOCM_FOR_0 | TIOCM_FOR_1;
    int tmperrno;

    if (ioctl(fd, TIOCMBIS, &out) < 0) {
        tmperrno = errno;
        perror("ioctl");
        errno = tmperrno;
        return -1;
    }

    if (usec_delay(InterBitDelay) < 0)
        return -1;
    
    return 0;
}

int x10_br_out(int fd, unsigned char unit, int cmd)
{
    unsigned char cmd_seq[5] = { 0xd5, 0xaa, 0x00, 0x00, 0xad };
    register int i;
    register int j;
    unsigned char byte;
    int out;
    int housecode;
    int device;
    int serial_state;
    int tmperrno;
#ifdef USE_CLOCAL
    struct termios termios;
    struct termios tmp_termios;
#endif

    /*
     * Make sure to set the numeric part of the device address to 0
     *  for dim/bright (they only work per housecode)
     */
    
    if ((cmd == DIM) || (cmd == BRIGHT))
        unit &= 0xf0;

#ifdef USE_CLOCAL

    if (tcgetattr(fd, &termios) < 0) {
        tmperrno = errno;
        perror("ioctl");
        errno = tmperrno;
        return -1;
    }

    tmp_termios = termios;

    tmp_termios.c_cflag |= CLOCAL;

    if (tcsetattr(fd, TCSANOW, &tmp_termios) < 0) {
        tmperrno = errno;
        perror("ioctl");
        errno = tmperrno;
        return -1;
    }

#endif

    /*
     * Save current state of bits we don't want to touch in serial
     *  register
     */
    
    if (ioctl(fd, TIOCMGET, &serial_state) < 0) {
        tmperrno = errno;
        perror("ioctl");
        errno = tmperrno;
        return -1;
    }

    /* Save state of lines to be mucked with
     */

    serial_state &= (TIOCM_FOR_0 | TIOCM_FOR_1);

    /* Figure out which ones we're going to want to clear
     *  when finished (they'll both be high after the last
     *  clock_out)
     */

    serial_state ^= (TIOCM_FOR_0 | TIOCM_FOR_1);

    /*
     * Open with a clock pulse to let the receiver get its wits about 
     */


    housecode = unit >> 4;
    device = unit & 0x0f;

    if ((cmd > MAX_CMD) || (cmd < 0))
        return -1;

    /*
     * Slap together the variable part of a command
     */

    cmd_seq[2] |= housecode_table[housecode] << 4 | device_table[device][0];
    cmd_seq[3] |= device_table[device][1] | cmd_table[cmd];

    /*
     * Set lines to clock and wait, to make sure receiver is ready
     */

    if (clock_out(fd) < 0)
        return -1;

    if (usec_sleep(PreCmdDelay) < 0)
        return -1;

    for (j = 0; j < 5; j++) {
        byte = cmd_seq[j];

        /*
         * Roll out the bits, following each one by a "clock".
         */

        for (i = 0; i < 8; i++) {
            out = (byte & 0x80) ? 1:0;
            byte <<= 1;
            if ((bits_out(fd, out) < 0) || (clock_out(fd) < 0))
                return -1;
        }
    }

    /*
     * Close with a clock pulse and wait a bit to allow command to complete
     */

    if (clock_out(fd) < 0)
        return -1;
    
    if (usec_sleep(PostCmdDelay) < 0)
        return -1;

   if (ioctl(fd, TIOCMBIC, &serial_state) < 0) {
        tmperrno = errno;
        perror("ioctl");
        errno = tmperrno;
        return -1;
    }

#ifdef USE_CLOCAL
    if (tcsetattr(fd, TCSANOW, &termios) < 0) {
        tmperrno = errno;
        perror("tcsetattr");
        errno = tmperrno;
        return -1;
    }
#endif

    return 0;
}

typedef struct {
    int inverse;
    int repeat;
    char *port;
    int fd;
    int numcmds;
    int devs[MAX_COMMANDS];
    char houses[MAX_COMMANDS];
    int dimlevels[MAX_COMMANDS];
    int cmds[MAX_COMMANDS];
} br_control_info;

int Verbose = 0;
char *MyName = "br";

int checkimmutableport(char *port_source)
{
/*
 * Check to see if the user is allowed to specify an alternate serial port
 */

    if (!ISSETID())
        return 0;

    fprintf(stderr, "%s:  You are not authorized to change the X10 port!\n",
      MyName);
    fprintf(stderr, "%s:  Invalid port assignment %s.\n", MyName, port_source);

    errno = EINVAL;

    return -1;
}

int gethouse(char *house)
{
    int c;

    c = house[0] - 'A';
    if ((strlen(house) > 1) || (c < 0) || (c > 15)) {
        fprintf(stderr, "%s:  House code must be in range [A-P]\n", MyName);
        errno = EINVAL;
        return -1;
    }

    return c;
}

int getdim(char *list, int *dim)
{
/*
 * Get devices that should be dimmed from the command line, and how
 *  much to dim them
 */    
    
    char *end;
    int dev;
    int devs = 0;
    
    *dim = strtol(list, &end, 0);
    
    /*
     * May have more dimlevels when I get a chance to play with variable
     *  dimming
     */

    if (((*end != '\0') && (*end != ',')) 
        || (*dim < -DIMRANGE) 
        || (*dim > DIMRANGE)) 
    {
        fprintf(stderr, "%s:  For dimming either specify just a dim level or "
          "a comma\n",MyName);
        fprintf(stderr, "separated list containing the dim level and the "
          "devices to dim.\n");
        fprintf(stderr, "%s:  Valid dimlevels are numbers between %d and %d.\n",
          MyName, -DIMRANGE, DIMRANGE);
        errno = EINVAL;
        return -1;
    }

    list = end;

    while (*list++) {
        dev = strtol(list, &end, 0);

        if ((dev > 16) 
            || (dev < 1) 
            || ((*end != '\0') && (*end != ','))) 
        {
            fprintf(stderr, "%s:  Devices must be in the range of 1-16.\n", 
              MyName);
            errno = EINVAL;
            return -1;
        }

        devs |= 1 << (dev - 1);

        list = end;
    }

    return devs;
}


int getdevs(char *list)
{
/*
 * Get a list of devices for an operation to be performed on from
 *  the command line
 */

    int devs = 0;
    int dev;
    char *end;


    do {
        dev = strtol(list, &end, 0);

        if ((dev > 16) 
            || (dev < 1) 
            || ((*end != '\0') && (*end != ','))) 
        {
            fprintf(stderr, "%s:  Devices must be in the range of 1-16\n", 
              MyName);
            errno = EINVAL;
            return -1;
        }

        /*
         * Set the bit corresponding to the given device
         */

        devs |= 1 << (dev - 1);

        list = end;
    } while (*list++); /* Skip the , */

    return devs;
}


int br_getunit(char *arg, int *house, int *devs)
{
/*
 * Get units to be accessed from the command line in native BottleRocket style
 */

    if (strlen(arg) < 2) {
        errno = EINVAL;
        return -1;
    }

    if ((*devs = getdevs(arg + 1)) < 0)
        return -1;

    *(arg + 1) = '\0';

    if ((*house = gethouse(arg)) < 0)
        return -1;

    return 0;
}

int br_native_getcmd(char *arg)
{
/*
 * Convert a native BottleRocket command to the appropriate token
 */

    if (!strcasecmp(arg, "ON"))
        return ON;

    if (!strcasecmp(arg, "OFF"))
        return OFF;

    if (!strcasecmp(arg, "DIM"))
        return DIM;

    if (!strcasecmp(arg, "BRIGHT"))
        return BRIGHT;

    if (!strcasecmp(arg, "ALL_ON"))
        return ALL_ON;

    if (!strcasecmp(arg, "ALL_OFF"))
        return ALL_OFF;

    if (!strcasecmp(arg, "LAMPS_ON"))
        return ALL_LAMPS_ON;

    if (!strcasecmp(arg, "LAMPS_OFF"))
        return ALL_LAMPS_OFF;

    fprintf(stderr, "%s:  Command must be one of ON, OFF, DIM, BRIGHT, "
	    "ALL_ON, ALL_OFF, LAMPS_ON or LAMPS_OFF.\n", MyName);
    errno = EINVAL;

    return -1;
}

int process_list(int fd, int house, int devs, int cmd)
{
/*
 * Process and execute on/off commands on a cluster of devices
 */

    unsigned short unit;
    int i;

    /* apply cmd to devices in list */
    
    for (i = 0; i < 16; i++) {
        if (devs & (1 << i)) {
            unit = (unsigned char)((house << 4) | i);
			if (VERBOSE > 0)
                printf("%s:  Turning %s appliance %c%d\n", MyName,
                  (cmd == ON) ? "on":"off", HOUSENAME(house), DEVNAME(i));
         
             if (x10_br_out(fd, unit, (unsigned char)cmd) < 0)
                 return -1;
        }
    }
    
    return 0;
}


int process_dim(int fd, int house, int devs, int dim)
{

    register int i;
    int unit = (unsigned char)(house << 4);
    int cmd = (dim < 0) ? DIM:BRIGHT;
    int tmpdim;

    
    dim = (dim < 0) ? -dim:dim;
    tmpdim = dim;
    
    if (!devs) {
        if (VERBOSE > 1)
            printf("%s:  %s lamps in house %c by %d.\n", MyName,
              (cmd == BRIGHT) ? "Brightening":"Dimming", HOUSENAME(house), dim);
        for (; tmpdim; tmpdim--) {
            if (x10_br_out(fd, unit, (unsigned char)cmd) < 0)
                return -1;
        }
    } else {
        for (i = 0; i < 16; i++) {
            if (devs & (1 << i)) {
                if (VERBOSE > 0)
                    printf("%s:  %s lamp %c%d by %d.\n", MyName,
                      (cmd == BRIGHT) ? "Brightening":"Dimming", 
                      HOUSENAME(house), DEVNAME(i), dim);
                /* Send an ON cmd to select the device this may change later */
                if (x10_br_out(fd, unit | i, ON) < 0)
                    return -1;
                
                for (; tmpdim > 0; tmpdim--)
                    if (x10_br_out(fd, unit, (unsigned char)cmd) < 0)
                        return -1;
                tmpdim = dim;
            }
        }
    }
    
    return 0;
}

int open_port(br_control_info *cinfo)
{
/*
 * Open the serial port that a FireCracker device is (we expect) on
 */

    int tmperrno;

    if (VERBOSE > 0)
        printf("%s:  Opening serial port %s.\n", MyName, cinfo->port);

    /*
     * Oh, yeah.  Don't need O_RDWR for ioctls.  This is safer.
     */
        
    if ((cinfo->fd = open(cinfo->port, O_RDONLY | O_NONBLOCK)) < 0) {
	tmperrno = errno;
        fprintf(stderr, "C_%s: Error (%s) opening %s.\n", MyName, 
          strerror(errno), cinfo->port);
	errno = tmperrno;
        return -1;
    }
    
    /*
     * If we end up with a reserved fd, don't mess with it.  Just to make sure.
     */
    
    if (!SAFE_FILENO(cinfo->fd)) {
        close(cinfo->fd);
        errno = EBADF;
        return -1;
    }

    return 0;
}

int close_port(br_control_info *cinfo)
{
/*
 * Close the serial port when we're done using it
 */

    if (VERBOSE > 0)
        printf("%s:  Closing serial port.\n", MyName);

    close(cinfo->fd);

    return 0;
}


int addcmd(br_control_info *cinfo, int cmd, int house, int devs, int dimlevel)
{
    /*
     * Add a command, plus devices for it to act on and other info, to the
     *  list of commands to be executed
     */

    if (cinfo->numcmds >= MAX_COMMANDS) {
        fprintf(stderr, "C_%s:  Too many commands specified.\n", MyName);
        errno = EINVAL;
        return -1;
    }

    cinfo->cmds[cinfo->numcmds] = cmd;
    cinfo->devs[cinfo->numcmds] = devs;
    cinfo->dimlevels[cinfo->numcmds] = dimlevel;
    cinfo->houses[cinfo->numcmds] = house;

    cinfo->numcmds++;

    return 0;
}

int br_execute(br_control_info *cinfo)
{
/*
 * Run through a list of commands and execute them
 */

    register int i;
    register int repeat = cinfo->repeat;
    int inverse = cinfo->inverse;
    int cmd;

    for (; repeat > 0; repeat--) {
        for (i = 0; i < cinfo->numcmds; i++)
        {
            cmd = cinfo->cmds[i];
            if ((cmd == ON) || (cmd == OFF)) {
                cmd = (inverse >= 0) ? cmd : (cmd == OFF) ? ON:OFF;
    
                if (process_list(cinfo->fd, cinfo->houses[i],
                  cinfo->devs[i], cmd) < 0)
                {
                    return -1;
                }
            } else if ((cmd == ALL_ON) || (cmd == ALL_OFF)) {
                cmd = (inverse >= 0) ? cmd : (cmd == ALL_OFF) ? ALL_ON:ALL_OFF;
    
                if (x10_br_out(cinfo->fd, cinfo->houses[i] << 4, cmd) < 0)
                    return -1;
    
            } else if ((cmd == ALL_LAMPS_ON) || (cmd == ALL_LAMPS_OFF)) {
                cmd = (inverse >= 0) ? cmd : (cmd == ALL_LAMPS_OFF) ?
                  ALL_LAMPS_ON:ALL_LAMPS_OFF;
    
                if (x10_br_out(cinfo->fd, cinfo->houses[i] << 4, cmd) < 0)
                    return -1;
    
            } else if (cmd == DIM) {
                if (process_dim(cinfo->fd, cinfo->houses[i], cinfo->devs[i],
                  (inverse >= 0) ? 
                  cinfo->dimlevels[i]:-cinfo->dimlevels[i]) < 0)
                {
                    return -1;
                }
            }
        }
            
        if (inverse) inverse = 0 - inverse;
    }
    
    return 0;
}

int set_verbosity(int i)
{
	VERBOSE = i;
	return 0;
}

int set_x10_portname(char *port)
{
	X10_PORTNAME = port;
	return 0;
}

char get_x10_portname(void)
{
	if (X10_PORTNAME == NULL)
		return -1;
	else 
		return 0;
}

int br(char *command, char *letter, char *device, int dimlevel)
{
    char *port_source = "at compile time";
    char *tmp_port;
    int opt;
	int cmd;
    int house = 0;
    int repeat;
    int dev;
    br_control_info *cinfo = NULL;
    int tmperrno;
    
#ifdef HAVE_GETOPT_LONG    
    int opt_index;
    static struct option long_options[] = {
        {"help",  	no_argument, 	    	0, 'h'},
        {"port",  	required_argument, 	0, 'x'},
        {"repeat",	required_argument, 	0, 'r'},
        {"on", 		required_argument, 	0, 'n'},
        {"off", 	required_argument, 	0, 'f'},
        {"ON", 		no_argument, 		0, 'N'},
        {"OFF", 	no_argument, 		0, 'F'},
        {"dim", 	required_argument, 	0, 'd'},
        {"lamps_on", 	no_argument, 		0, 'B'},
        {"lamps_off", 	no_argument, 		0, 'D'},
        {"inverse", 	no_argument, 		0, 'i'},
	{"house",	required_argument,	0, 'c'},
	{"verbose",	no_argument,		0, 'v'},
	{0, 0, 0, 0}
    };
#endif

#define OPT_STRING	"x:hvr:ic:n:Nf:Fd:BD"
    
    if ((cinfo = malloc(sizeof(br_control_info))) == NULL) {
	tmperrno = errno;
        fprintf(stderr, "C_%s: Error (%s) allocating memory.\n", MyName,
          strerror(errno));
        exit(tmperrno);
    }
    
    CINFO_CLR(cinfo);
    cinfo->port = X10_PORTNAME;
    cinfo->repeat = 1;
    
    if ((tmp_port = getenv("X10_PORTNAME"))) {
        port_source = "in the environment variable X10_PORTNAME";
        if (!checkimmutableport(port_source))
            cinfo->port = tmp_port;
    }

	house = gethouse(letter); 
	cmd = br_native_getcmd(command);
	dev = getdevs(device);
    addcmd(cinfo, cmd, house, dev, dimlevel);
	open_port(cinfo);
	br_execute(cinfo);
	close_port(cinfo);
	free(cinfo);
}
<#

(use utils)

; main interfaces to c functions and variables

(define C_version (foreign-value "VERSION" c-string))

(define C_set-verbosity
  (foreign-lambda int "set_verbosity" int))

(define C_set-x10-portname
  (foreign-lambda int "set_x10_portname" c-string))

(define C_get-x10-portname
  (foreign-lambda int "get_x10_portname"))

(define C_br
  (foreign-lambda int "br" c-string c-string c-string int))


; getters and setters

(define br-verbosity
  (lambda (x)
     (C_set-verbosity x)))

(define br-x10-portname
  (lambda (x)
     (C_set-x10-portname x)))

(define br-get-x10-portname
  (lambda ()
     (C_get-x10-portname)))

; wrappers to emulate commands

(define br
  (lambda (command dev dim)
	(cond
	   ((= -1 (br-get-x10-portname)) 
	     (display "You forgot to specify your serial port\n")
	     (display "Run (br-usage) to see how to set it   \n")
	     (exit))
	   ((= 0 (br-get-x10-portname)) 
         (let (
	       (zone (substring dev 0 1))
	       (dev  (substring dev 1 (string-length dev))))
	       (C_br command zone dev dim))))))

(define br-on
  (lambda (dev)
    (br "ON" dev 0)))

(define br-off
  (lambda (dev)
    (br "OFF" dev 0)))

(define br-dim
  (lambda (dev #!optional (dim -1))
    (br "DIM" dev dim)))

(define br-bright
  (lambda (dev dim #!optional (dim 1))
    (br "BRIGHT" x)))

(define br-all-on
  (lambda (dim)
    (br "ALL_ON" x 1)))

(define br-all-off
  (lambda (dim)
    (br "ALL_OFF" dim 0)))

(define br-all-lamps-on
  (lambda (dim)
    (br "ALL_LAMPS_ON" x 1)))

(define br-all-lamps-off
  (lambda (x)
    (br "ALL_LAMPS_OFF" x 1)))

(define br-help
  (lambda ()
	(display "\n")
    (display 
	 (format "  BottleRocket version ~a\n\n" C_version))
	(display "  Description:\n")
    (display "    This is a Chicken Scheme wrapper for the BottleRocket\n")
	(display "    utilites provided to trigger X10 events\n\n")
    (display "  Main Utility:\n") 
	(display "   (br [command] [housecode] [device] [dimlevel])\n")
	(display "   *** You shouldn't need to call this procedure directly\n\n")
    (display "  Commands:\n")
    (display "   (br-set-verbosity [value])  set to adjust verbosity\n")
    (display "   (br-set-x10-port [device])  set serial port to use\n")
    (display "   (br-on [device])            turn on all devices in housecode\n")
    (display "   (br-off [device])           turn off all devices in housecode\n")
    (display "   (br-dim [dimlevel])         dim devices in housecode to\n")
    (display "   (br-all-lamps-on)           turn all lamps in housecode on\n")
    (display "   (br-all-lamps-off)          turn all lamps in housecode off\n")
    (display "   (br-help)                   this help\n\n")))

;(br-x10-portname "/dev/ttySAC0")
;(br-verbosity 1)
;(br-on "A1")

