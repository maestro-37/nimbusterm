import os
import socket
import subprocess
import sys
import threading
import time

import paramiko

ROOT = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else "/tmp/nimbusterm-sftp")
PORT = int(sys.argv[2]) if len(sys.argv) > 2 else 2222
os.makedirs(ROOT, exist_ok=True)


class Server(paramiko.ServerInterface):
    def check_auth_password(self, username, password):
        if username == "test" and password == "test":
            return paramiko.AUTH_SUCCESSFUL
        return paramiko.AUTH_FAILED

    def check_auth_publickey(self, username, key):
        if username == "test":
            return paramiko.AUTH_SUCCESSFUL
        return paramiko.AUTH_FAILED

    def get_allowed_auths(self, username):
        return "publickey,password"

    def check_channel_request(self, kind, chanid):
        if kind == "session":
            return paramiko.OPEN_SUCCEEDED
        return paramiko.OPEN_FAILED_ADMINISTRATIVELY_PROHIBITED

    def check_channel_exec_request(self, channel, command):
        def run():
            process = subprocess.Popen(command, shell=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
            output = process.communicate()[0]
            channel.sendall(output)
            channel.send_exit_status(process.returncode)
            channel.close()

        threading.Thread(target=run, daemon=True).start()
        return True


class Handle(paramiko.SFTPHandle):
    def __init__(self, fileobj, flags):
        super().__init__(flags)
        self.fileobj = fileobj

    def read(self, offset, length):
        self.fileobj.seek(offset)
        return self.fileobj.read(length)

    def write(self, offset, data):
        self.fileobj.seek(offset)
        self.fileobj.write(data)
        self.fileobj.flush()
        return len(data)

    def close(self):
        self.fileobj.close()
        return paramiko.SFTP_OK

    def stat(self):
        return paramiko.SFTPAttributes.from_stat(os.fstat(self.fileobj.fileno()))


class Filesystem(paramiko.SFTPServerInterface):
    def _real(self, path):
        clean = "/" + path.lstrip("/")
        real = os.path.abspath(os.path.join(ROOT, clean.lstrip("/").replace("..", "")))
        if not real.startswith(ROOT):
            raise ValueError("outside root")
        return real

    def list_folder(self, path):
        try:
            real = self._real(path)
            result = []
            for name in os.listdir(real):
                attr = paramiko.SFTPAttributes.from_stat(os.lstat(os.path.join(real, name)))
                attr.filename = name
                result.append(attr)
            return result
        except Exception:
            return paramiko.SFTP_FAILURE

    def stat(self, path):
        try:
            return paramiko.SFTPAttributes.from_stat(os.stat(self._real(path)))
        except Exception:
            return paramiko.SFTP_FAILURE

    def lstat(self, path):
        try:
            return paramiko.SFTPAttributes.from_stat(os.lstat(self._real(path)))
        except Exception:
            return paramiko.SFTP_FAILURE

    def open(self, path, flags, attr):
        try:
            real = self._real(path)
            if flags & os.O_WRONLY:
                mode = "ab" if flags & os.O_APPEND else ("r+b" if os.path.exists(real) and not flags & os.O_TRUNC else "wb")
            elif flags & os.O_RDWR:
                mode = "r+b"
            else:
                mode = "rb"
            if flags & os.O_CREAT and not os.path.exists(real):
                open(real, "ab").close()
            return Handle(open(real, mode), flags)
        except Exception:
            return paramiko.SFTP_FAILURE

    def remove(self, path):
        try:
            os.remove(self._real(path))
            return paramiko.SFTP_OK
        except Exception:
            return paramiko.SFTP_FAILURE

    def rename(self, oldpath, newpath):
        try:
            os.replace(self._real(oldpath), self._real(newpath))
            return paramiko.SFTP_OK
        except Exception:
            return paramiko.SFTP_FAILURE

    def mkdir(self, path, attr):
        try:
            mode = attr.st_mode if attr and attr.st_mode else 0o755
            os.mkdir(self._real(path), mode)
            return paramiko.SFTP_OK
        except Exception:
            return paramiko.SFTP_FAILURE

    def rmdir(self, path):
        try:
            os.rmdir(self._real(path))
            return paramiko.SFTP_OK
        except Exception:
            return paramiko.SFTP_FAILURE

    def chattr(self, path, attr):
        try:
            real = self._real(path)
            if attr.st_mode:
                os.chmod(real, attr.st_mode)
            if attr.st_atime or attr.st_mtime:
                os.utime(real, (attr.st_atime or time.time(), attr.st_mtime or time.time()))
            return paramiko.SFTP_OK
        except Exception:
            return paramiko.SFTP_FAILURE

    def symlink(self, target_path, path):
        try:
            os.symlink(self._real(target_path), self._real(path))
            return paramiko.SFTP_OK
        except Exception:
            return paramiko.SFTP_FAILURE

    def readlink(self, path):
        try:
            return os.readlink(self._real(path))
        except Exception:
            return paramiko.SFTP_FAILURE

    def canonicalize(self, path):
        return "/" + os.path.normpath("/" + path).lstrip("/")


HOST_KEY = paramiko.RSAKey.generate(2048)


def handle(client):
    try:
        transport = paramiko.Transport(client)
        transport.add_server_key(HOST_KEY)
        transport.set_subsystem_handler("sftp", paramiko.SFTPServer, Filesystem)
        transport.start_server(server=Server())
        channel = transport.accept(20)
        if channel is None:
            transport.close()
            return
        while transport.is_active():
            time.sleep(0.2)
    except Exception as exc:
        print("connection error:", exc, file=sys.stderr)
    finally:
        try:
            client.close()
        except Exception:
            pass


def main():
    server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server.bind(("127.0.0.1", PORT))
    server.listen(20)
    print(f"SFTP test server on 127.0.0.1:{PORT}, root={ROOT}", flush=True)
    while True:
        client, _ = server.accept()
        threading.Thread(target=handle, args=(client,), daemon=True).start()


if __name__ == "__main__":
    main()
