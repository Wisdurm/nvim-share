#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <sys/socket.h>
#include <netinet/tcp.h>
#include <netinet/in.h>
#include <poll.h>
#include <string.h>

#define MAX_CLIENTS 64

struct client {
	int is_host;
};

struct server {
	struct pollfd fds[MAX_CLIENTS];
	struct client clients[MAX_CLIENTS];
	int nfds;
	int host_fd;
};

static void remove_client(struct server *srv, int idx)
{
	int fd = srv->fds[idx].fd;
	printf("Client on socket %d disconnected\n", fd);
	close(fd);

	if (srv->clients[idx].is_host)
		srv->host_fd = -1;

	/* Move last element to current position to fill gap */
	srv->fds[idx] = srv->fds[srv->nfds - 1];
	srv->clients[idx] = srv->clients[srv->nfds - 1];
	srv->nfds--;
}

static void accept_connection(int server_fd, struct server *srv)
{
	int new_fd = accept(server_fd, NULL, NULL);
	if (new_fd < 0) {
		fprintf(stderr, "Accept failed\n");
		return;
	}

	if (srv->nfds >= MAX_CLIENTS) {
		fprintf(stderr, "Too many clients\n");
		close(new_fd);
		return;
	}

	int opt = 1;
	setsockopt(new_fd, IPPROTO_TCP, TCP_NODELAY, &opt, sizeof(opt));

	srv->fds[srv->nfds].fd = new_fd;
	srv->fds[srv->nfds].events = POLLIN;

	int is_host = (srv->host_fd < 0);
	srv->clients[srv->nfds].is_host = is_host;
	if (is_host)
		srv->host_fd = new_fd;

	printf("New connection: %d%s\n", new_fd, is_host ? " (host)" : "");
	srv->nfds++;
}

/* Sends list of connected sockets to lua client */
static void handle_query(int client_fd, struct server *srv)
{
	char resp[1024];
	int len = 0;

	/* Skip index 0 (server socket) */
	for (int i = 1; i < srv->nfds && len < (int)sizeof(resp); ++i) {
		int fd = srv->fds[i].fd;
		int is_host = srv->clients[i].is_host;
		len += snprintf(resp + len, sizeof(resp) - len, "%d%s\n", fd,
				is_host ? " HOST" : "");
	}
	send(client_fd, resp, (size_t)len, 0);
}

static int handle_client_data(struct server *srv, int idx)
{
	char buf[1024];
	ssize_t n = recv(srv->fds[idx].fd, buf, sizeof(buf) - 1, 0);

	/* Usually happens on disconnect */
	if (n <= 0) {
		remove_client(srv, idx);
		return -1;
	}

	buf[n] = '\0';
	printf("Got %zd bytes from %d: %s\n", n, srv->fds[idx].fd, buf);

	/* Handle commands */
	if (strncmp(buf, "QUERY", 5) == 0)
		handle_query(srv->fds[idx].fd, srv);
	return 0;
}

int main(void)
{
	/* Create server socket (IPv4, stream... TCP)*/
	int server_fd = socket(AF_INET, SOCK_STREAM, 0);
	if (server_fd < 0) {
		fprintf(stderr, "Socket creation failed\n");
		return 1;
	}

	/* Disable Nagle (to reduce delay) and make sure that the kernel
	 * reclaims port immidietly after closing the socket */
	int opt = 1;
	setsockopt(server_fd, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt));
	setsockopt(server_fd, IPPROTO_TCP, TCP_NODELAY, &opt, sizeof(opt));

	/* Create socket address with port 8080, and IP 0.0.0.0 */
	struct sockaddr_in addr = { .sin_family = AF_INET,
				    .sin_port = htons(8080),
				    .sin_addr.s_addr = INADDR_ANY };

	if (bind(server_fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
		fprintf(stderr, "Bind failed\n");
		return 1;
	}

	if (listen(server_fd, MAX_CLIENTS) < 0) {
		fprintf(stderr, "Listen failed\n");
		return 1;
	}

	printf("Listening...\n");

	/* Create server that requests POLLIN events. nfds = number of file
	 * descriptions (thank GNU) */
	struct server srv = { .nfds = 1, .host_fd = -1 };
	srv.fds[0].fd = server_fd;
	srv.fds[0].events = POLLIN;

	/* Take up main thread to listen incoming POLLIN events */
	while (poll(srv.fds, (nfds_t)srv.nfds, -1) >= 0) {
		for (int i = 0; i < srv.nfds; ++i) {
			if (srv.fds[i].revents &
			    (POLLERR | POLLHUP | POLLNVAL)) {
				/* TODO: print error to stderr */
				remove_client(&srv, i);
				i--;
				continue;
			}

			if (srv.fds[i].revents & POLLIN) {
				if (srv.fds[i].fd == server_fd)
					accept_connection(server_fd, &srv);
				else if (handle_client_data(&srv, i) < 0)
					i--;
			}
		}
	}

	close(server_fd);
	return 0;
}
