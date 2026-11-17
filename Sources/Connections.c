#include <sys/types.h>
#include <sys/socket.h>
#include <sys/socketvar.h>
#include <sys/sysctl.h>
#include <netinet/in.h>
#include <netinet/in_pcb.h>
#include <netinet/tcp_var.h>
#include <netinet/tcp_fsm.h>
#include <arpa/inet.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <stdio.h>

// Read the kernel snapshot in-process: no external collector or timer job.
// Unknown layouts, incomplete snapshots and denied reads return NULL, never 0 peers.
char *screenpeers_connections(void) {
    const char *key = "net.inet.tcp.pcblist64";
    size_t size = 0;
    if (sysctlbyname(key, NULL, &size, NULL, 0) != 0 || size < sizeof(struct xinpgen)) return NULL;
    size = size + size / 2 + 4096;
    unsigned char *buffer = malloc(size);
    if (!buffer) return NULL;
    if (sysctlbyname(key, buffer, &size, NULL, 0) != 0) { free(buffer); return NULL; }
    struct xinpgen *head = (struct xinpgen *)buffer;
    if (head->xig_len != sizeof(struct xinpgen)) { free(buffer); return NULL; }
    size_t capacity = size + 1;
    char *output = calloc(capacity, 1);
    if (!output) { free(buffer); return NULL; }
    size_t used = 0, offset = head->xig_len;
    int complete = 0;
    while (offset + sizeof(uint32_t) <= size) {
        uint32_t length;
        memcpy(&length, buffer + offset, sizeof(length));
        if (length < sizeof(struct xinpgen) || offset + length > size) break;
        if (length == sizeof(struct xinpgen)) { complete = 1; break; }
        if (length < sizeof(struct xtcpcb64)) break;
        struct xtcpcb64 *tcp = (struct xtcpcb64 *)(buffer + offset);
        struct xinpcb64 *ip = &tcp->xt_inpcb;
        if (ntohs(ip->inp_lport) == 5900 && tcp->t_state == TCPS_ESTABLISHED
            && ip->inp_gencnt <= head->xig_gen) {
            char address[INET6_ADDRSTRLEN];
            const char *value = NULL;
            if (ip->inp_vflag & INP_IPV4) value = inet_ntop(AF_INET, &ip->inp_faddr, address, sizeof(address));
            else if (ip->inp_vflag & INP_IPV6) value = inet_ntop(AF_INET6, &ip->in6p_faddr, address, sizeof(address));
            if (value && used + strlen(value) + 2 < capacity) {
                used += snprintf(output + used, capacity - used, "%s\n", value);
            }
        }
        offset += length;
    }
    free(buffer);
    if (!complete) { free(output); return NULL; }
    return output;
}
