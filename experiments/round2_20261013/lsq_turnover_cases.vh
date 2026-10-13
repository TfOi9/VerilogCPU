        // A waiting load may be scheduled only after the preceding response fires.
        reset_case();
        allocate_one(0, tag(0), `RV32_MEMORY_WORD, 0, first_tag);
        allocate_one(0, tag(1), `RV32_MEMORY_WORD, 0, second_tag);
        load_address(tag(0), first_tag, 32'h100);
        expect_request(0, 32'h100, 0);
        load_address(tag(1), second_tag, 32'h104);
        repeat (3) begin
            tick();
            check(!cache_request_valid_o, "no second outstanding request");
        end
        send_response(32'h12345678, 0);
        #1;
`ifdef EXPECT_TURNOVER
        check(cache_request_valid_o, "response schedules next request");
`else
        check(!cache_request_valid_o, "baseline response scheduling bubble");
        tick();
`endif
        repeat (3) begin
            check(cache_request_valid_o && cache_request_address_o == 32'h104,
                "turnover request stable under backpressure");
            check(completion_valid_o && completion_rob_tag_o == tag(0) &&
                completion_value_o == 32'h12345678,
                "first completion stable under backpressure");
            tick();
        end
        expect_request(0, 32'h104, 0);
        cache_response_valid_i = 1;
        cache_response_error_i = 1;
        repeat (3) begin
            #1; check(!cache_response_ready_o,
                "second response blocked by occupied completion");
            tick();
        end
        expect_completion(tag(0), 32'h12345678, 0, 0);
        #1; check(cache_response_ready_o, "response unblocks after completion");
        tick(); cache_response_valid_i = 0; cache_response_error_i = 0;
        expect_completion(tag(1), 0, 1, 5);
        repeat (3) tick();
        check(!cache_request_valid_o && !completion_valid_o,
            "turnover does not duplicate a request or completion");

        // Recovery blocks the response; a surviving load follows its discard.
        reset_case();
        allocate_one(0, tag(0), `RV32_MEMORY_WORD, 0, first_tag);
        allocate_one(0, tag(1), `RV32_MEMORY_WORD, 0, second_tag);
        load_address(tag(0), first_tag, 32'h100);
        expect_request(0, 32'h100, 0);
        load_address(tag(1), second_tag, 32'h104);
        recover_i = 1; rollback_valid_i[0] = 1;
        rollback_rob_tag_i[0 +: ROB_TAG_WIDTH] = tag(0);
        rollback_lsq_tag_i[0 +: LSQ_TAG_WIDTH] = first_tag;
        cache_response_valid_i = 1; cache_response_read_data_i = 32'hdeadbeef;
        cache_response_error_i = 1;
        #1; check(!cache_response_ready_o && !cache_request_valid_o,
            "recovery suppresses turnover handshakes");
        tick(); recover_i = 0; rollback_valid_i = 0;
        #1; check(cache_response_ready_o, "discard response ready");
        tick(); cache_response_valid_i = 0; cache_response_error_i = 0;
        #1; check(!completion_valid_o, "discarded error has no completion");
`ifdef EXPECT_TURNOVER
        check(cache_request_valid_o, "discard permits next request scheduling");
`else
        check(!cache_request_valid_o, "baseline discard scheduling bubble");
        tick();
`endif
        expect_request(0, 32'h104, 0);
        send_response(32'habcdef01, 0);
        expect_completion(tag(1), 32'habcdef01, 0, 0);
