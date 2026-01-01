#include <stdio.h>
#include <unistd.h>
#include <sys/socket.h>
#include <netinet/tcp.h>
#include <netinet/in.h>

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
	listen(server_fd, 10);

	int client_fd = accept(server_fd, 0, 0);

	char buffer[1024] = { 0 };
	read(client_fd, buffer, 1024);
	printf("Received: %s\n", buffer);

	write(client_fd, "Hello\n", 6);

	close(client_fd);
	close(server_fd);
	return 0;
}