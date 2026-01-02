#include <stdio.h>
#include <unistd.h>
#include <sys/socket.h>
#include <netinet/tcp.h>
#include <netinet/in.h>
#include <poll.h>

#define MAX_CLIENTS 64

struct client {
	int fd;
	int is_host;
};

static void remove_client(int idx, struct pollfd *fds, struct client *clients,
			  int *nfds, int *host_fd)
{
	close(fds[idx].fd);
	if (clients[idx].is_host)
		*host_fd = -1;

	fds[idx] = fds[*nfds - 1];
	clients[idx] = clients[*nfds - 1];
	(*nfds)--;
}

static void accept_new_connection(int server_fd, struct pollfd *fds,
				  struct client *clients, int *nfds,
				  int *host_fd)
{
	int new_fd = accept(server_fd, NULL, NULL);
	if (new_fd < 0) {
		fprintf(stderr, "Accept failed\n");
		return;
	}

	if (*nfds >= MAX_CLIENTS) {
		fprintf(stderr, "Too many clients %d\n", new_fd);
		close(new_fd);
		return;
	}

	int opt = 1;
	setsockopt(new_fd, IPPROTO_TCP, TCP_NODELAY, &opt, sizeof(opt));
	fds[*nfds].fd = new_fd;
	fds[*nfds].events = POLLIN;
	clients[*nfds].fd = new_fd;
	clients[*nfds].is_host = (*host_fd < 0);
	if (*host_fd < 0)
		*host_fd = new_fd;
	(*nfds)++;

	printf("New connection on socket %d%s\n", new_fd,
	       clients[*nfds - 1].is_host ? " (host)" : "");
}

int main(void)
{
	int server_fd = socket(AF_INET, SOCK_STREAM, 0);

	int opt = 1;
	setsockopt(server_fd, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt));
	setsockopt(server_fd, IPPROTO_TCP, TCP_NODELAY, &opt, sizeof(opt));

	struct sockaddr_in addr = { .sin_family = AF_INET,
				    .sin_port = htons(8080),
				    .sin_addr.s_addr = INADDR_ANY };

	bind(server_fd, (struct sockaddr *)&addr, sizeof(addr));
	listen(server_fd, MAX_CLIENTS);

	struct pollfd fds[MAX_CLIENTS] = { 0 };
	struct client clients[MAX_CLIENTS] = { 0 };
	fds[0] = (struct pollfd){ .fd = server_fd, .events = POLLIN };
	clients[0] = (struct client){ .fd = server_fd, .is_host = 0 };
	int nfds = 1;

	int host_fd = -1;

	while (poll(fds, (nfds_t)nfds, -1) >= 0) {
		for (int i = 0; i < nfds; ++i) {
			/* Drop connection if error, hangup, or invalid request
			 * TODO: fix problem after one POLL ERR all subsequent
			 * polls fail
			 */
			if (fds[i].revents & (POLLERR | POLLHUP | POLLNVAL)) {
				printf("Client on socket %d dropped\n",
				       fds[i].fd);
				remove_client(i, fds, clients, &nfds, &host_fd);
				i--;
				continue;
			}

			/* If no data, skip */
			if (!(fds[i].revents & POLLIN))
				continue;

			/* New connection */
			if (fds[i].fd == server_fd) {
				accept_new_connection(server_fd, fds, clients,
						      &nfds, &host_fd);
				continue;
			}

			/* Receive data from client */
			char buf[512];
			ssize_t n = recv(fds[i].fd, buf, sizeof(buf), 0);
			if (n <= 0) {
				printf("Client on socket %d disconnected\n",
				       fds[i].fd);
				remove_client(i, fds, clients, &nfds, &host_fd);
				i--;
				continue;
			}

			printf("Received %zd bytes from socket %d: %.*s\n", n,
			       fds[i].fd, (int)n, buf);
		}
	}

	for (int i = 0; i < nfds; ++i)
		close(fds[i].fd);

	close(server_fd);

	return 0;
}