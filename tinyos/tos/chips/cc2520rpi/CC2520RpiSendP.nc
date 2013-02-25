#include "CC2520RpiDriver.h"

module CC2520RpiSendP {
  provides {
    interface Init as SoftwareInit @exactlyonce();
    interface BareSend;
  }
  uses {
    interface PacketMetadata;
    interface IO;
  }
}

implementation {

  typedef struct {
    message_t* ptr_to_msg;
    uint8_t len;           // length field of the 802.15.4 packet
  } write_fifo_header_t;

  typedef struct {
    message_t* ptr_to_msg;
    ssize_t ret;
    uint8_t len;
  } read_fifo_header_t;

  int cc2520_read;
  int cc2520_write;
  int write_pipe[2];
  int read_pipe[2];

  read_fifo_header_t send_hdr;


#ifdef CC2520RPI_DEBUG
  void print_message (uint8_t* buf, uint8_t printlen) {
    char pbuf[2048];
    char *buf_ptr = NULL;
    int i;

    buf_ptr = pbuf;
    for (i = 0; i < printlen; i++) {
      buf_ptr += sprintf(buf_ptr, " 0x%02X", buf[i]);
    }

    *(buf_ptr) = '\0';
    printf("%s\n", pbuf);
  }
#endif

  task void sendDone_task() {

    switch (send_hdr.ret) {
      case CC2520_TX_BUSY:
      case CC2520_TX_ACK_TIMEOUT:
      case CC2520_TX_FAILED:
        call PacketMetadata.setWasAcked(send_hdr.ptr_to_msg, FALSE);
        break;
      case CC2520_TX_LENGTH:
        ERROR("INCORRECT LENGTH\n");
        break;
      case CC2520_TX_SUCCESS:
        call PacketMetadata.setWasAcked(send_hdr.ptr_to_msg, TRUE);
        break;
      default:
        if (send_hdr.ret == send_hdr.len - 1) {
          call PacketMetadata.setWasAcked(send_hdr.ptr_to_msg, TRUE);
        } else {
          ERROR("write() weird return code: %i\n", send_hdr.ret);
        }
        break;
    }

    signal BareSend.sendDone(send_hdr.ptr_to_msg, SUCCESS);
  }

  command error_t SoftwareInit.init() {
    int cc2520_file;
    int ret;

    // Open the character device for the CC2520
    cc2520_file = open("/dev/radio", O_RDWR);
    if (cc2520_file < 0) {
      ERROR("Could not open radio.\n");
      exit(1);
    }

    // Create a pipe to buffer the output
    ret = pipe(write_pipe);
    if (ret == -1) {
      ERROR("Could not create write pipe.\n");
      exit(1);
    }

    // Create a pipe to read back the meta information after a packet is sent
    ret = pipe(read_pipe);
    if (ret == -1) {
      ERROR("Could not create read pipe.\n");
      exit(1);
    }

    // Create a process that pulls from the fifo and calls send on the
    // cc2520 driver
    if (!fork()) {
      // CHILD
      write_fifo_header_t whdr;
      read_fifo_header_t rhdr;
      uint8_t pkt_buf[PACKET_BUFFER_LEN];
      close(read_pipe[0]);
      close(write_pipe[1]);

      {
        const char RX_STR[] = "-2520-Tx";
        char proc_name[17] = {0};
        prctl(PR_GET_NAME, proc_name, 0, 0, 0);
        if (strlen(proc_name) > (16 - strlen(RX_STR))) {
          strcpy(proc_name + 16 - strlen(RX_STR), RX_STR);
        } else {
          strcat(proc_name, RX_STR);
        }
        prctl(PR_SET_NAME, proc_name, 0, 0, 0);

        RADIO_PRINTF("Spawned TX Process (%d). TOS Process (%d)\n",
            getpid(), getppid());
      }

      while(1) {
        ssize_t len, ret_val;
        len = read(write_pipe[0], &whdr, sizeof(write_fifo_header_t));
        if (len == 0) {
          ERROR("Write pipe EOF.\n");
        } else if (len < 0) {
          ERROR("Pipe error: %i.\n", errno);
          close(read_pipe[1]);
          close(write_pipe[0]);
          exit(1);
        }

        // Set the length byte from the whdr
        pkt_buf[0] = whdr.len;
        // Read the actual packet
        // The remainder of the packet will be the length byte minus the two
        // crc bytes.
        len = read(write_pipe[0], pkt_buf + 1, whdr.len-2);
        if (len <= 0) {
          ERROR("Error reading from pipe.\n");
          close(read_pipe[1]);
          close(write_pipe[0]);
        }

        // When writing to the cc2520 driver, the length is the length byte
        // plus 1 (for itself) minux the 2 byte crc
        ret_val = write(cc2520_file, pkt_buf, whdr.len-1);

        // write the return code to the read fifo
        rhdr.ptr_to_msg = whdr.ptr_to_msg;
        rhdr.ret = ret_val;
        rhdr.len = whdr.len;
        ret_val = write(read_pipe[1], &rhdr, sizeof(read_fifo_header_t));
        if (ret_val == -1) {
          ERROR("Error writing to read pipe.\n");
        }
      }
    }

    // PARENT
    close(read_pipe[1]);
    close(write_pipe[0]);
    close(cc2520_file);

    cc2520_read = read_pipe[0];
    cc2520_write = write_pipe[1];

    // Add the packet send result pipe to the select() call
    call IO.registerFileDescriptor(cc2520_read);

    RADIO_PRINTF("registered sender.\n");

    return SUCCESS;
  }

  // Read from read_fifo to get send metadata for the last sent packet
  async event void IO.receiveReady () {
    ssize_t ret;

    ret = read(cc2520_read, &send_hdr, sizeof(read_fifo_header_t));
    if (ret <= 0) {
      ERROR("Could not read from read fifo.\n");
    }

    // Post a task to trigger sendDone so we can get out of the async
    post sendDone_task();
  }

  command error_t BareSend.send (message_t* msg) {
    write_fifo_header_t whdr;
    ssize_t ret;

#ifdef CC2520RPI_DEBUG
    {
      uint8_t sam, dam;
      uint8_t* buf = (uint8_t*) msg;
      sam = (buf[2] >> 6) & 0x3;
      dam = (buf[2] >> 2) & 0x3;
      RADIO_PRINTF("Sending a packet. len: %i\n", buf[0]);
      buf += 6;
      printf("    to:   ");
      if (dam == 2) {
        // short address
        print_message(buf, 2);
        buf += 2;
      } else if (dam == 3) {
        print_message(buf, 8);
        buf += 8;
      }
      printf("    from: ");
      if (sam == 2) {
        // short address
        print_message(buf, 2);
      } else if (sam == 3) {
        print_message(buf, 8);
      }
    }
#endif

    whdr.ptr_to_msg = msg;
    whdr.len = ((uint8_t*) msg)[0];
    ret = write(cc2520_write, &whdr, sizeof(write_fifo_header_t));
    if (ret == -1) {
      ERROR("could not write to fifo.\n");
    }

    // write the rest of the packet to the fifo
    // Write() the body of the packet (no length byte or 2 byte crc)
    ret = write(cc2520_write, ((uint8_t*)msg)+1, whdr.len-2);
    if (ret == -1) {
      ERROR("could not write to fifo.\n");
    }

    return SUCCESS;
  }

  command error_t BareSend.cancel (message_t* msg) {
    return FAIL;
  }
}
