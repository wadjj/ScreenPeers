#define sysctlbyname fixture_sysctlbyname
#include "../Sources/Connections.c"
#undef sysctlbyname
#include <assert.h>
#include <errno.h>

static unsigned char fixture[2 * sizeof(struct xinpgen) + sizeof(struct xtcpcb64)];
static int denied = 0;

int fixture_sysctlbyname(const char *name, void *old, size_t *size, void *newValue, size_t newSize) {
    (void)name; (void)newValue; (void)newSize;
    if (denied) { errno = EPERM; return -1; }
    if (old) memcpy(old, fixture, sizeof(fixture));
    *size = sizeof(fixture);
    return 0;
}

static struct xtcpcb64 *setup(void) {
    memset(fixture, 0, sizeof(fixture));
    struct xinpgen *head = (struct xinpgen *)fixture;
    head->xig_len = sizeof(*head);
    head->xig_gen = 10;
    struct xtcpcb64 *tcp = (struct xtcpcb64 *)(fixture + sizeof(*head));
    tcp->xt_len = sizeof(*tcp);
    tcp->xt_inpcb.inp_gencnt = 9;
    tcp->xt_inpcb.inp_lport = htons(5900);
    tcp->xt_inpcb.inp_vflag = INP_IPV4;
    inet_pton(AF_INET, "192.168.1.2", &tcp->xt_inpcb.inp_faddr);
    tcp->t_state = TCPS_ESTABLISHED;
    struct xinpgen *tail = (struct xinpgen *)(fixture + sizeof(*head) + sizeof(*tcp));
    tail->xig_len = sizeof(*tail);
    return tcp;
}

static void expect(const char *expected) {
    char *actual = screenpeers_connections();
    if (!expected) assert(actual == NULL);
    else { assert(actual != NULL); assert(strcmp(actual, expected) == 0); }
    free(actual);
}

int main(void) {
    struct xtcpcb64 *tcp = setup();
    expect("192.168.1.2\n");
    tcp->t_state = TCPS_LISTEN;
    expect("");
    tcp = setup(); tcp->xt_inpcb.inp_lport = htons(40000); tcp->xt_inpcb.inp_fport = htons(5900);
    expect("");
    tcp = setup(); tcp->xt_inpcb.inp_gencnt = 11;
    expect("");
    tcp = setup(); tcp->xt_inpcb.inp_vflag = INP_IPV6;
    inet_pton(AF_INET6, "2001:db8::1", &tcp->xt_inpcb.in6p_faddr);
    expect("2001:db8::1\n");
    tcp = setup(); tcp->xt_len = 1;
    expect(NULL);
    setup(); denied = 1;
    expect(NULL);
    puts("7 native connection scenarios passed");
    return 0;
}
