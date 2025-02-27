# frozen_string_literal: true
require "rails_helper"

module DiscoursePostEvent
  describe EventsController do
    before do
      Jobs.run_immediately!
      SiteSetting.calendar_enabled = true
      SiteSetting.discourse_post_event_enabled = true
      SiteSetting.displayed_invitees_limit = 3
    end

    let(:user) { Fabricate(:user, admin: true) }
    let(:topic) { Fabricate(:topic, user: user) }
    let(:post1) { Fabricate(:post, user: user, topic: topic) }
    let(:invitee1) { Fabricate(:user) }
    let(:invitee2) { Fabricate(:user) }

    context 'Existing post' do
      context 'Existing event' do
        let(:event_1) { Fabricate(:event, post: post1) }

        before do
          sign_in(user)
        end

        context 'when updating' do
          context 'when doing csv bulk invite' do
            let(:valid_file) {
              file = Tempfile.new("valid.csv")
              file.write("bob,going\n")
              file.write("sam,interested\n")
              file.write("the_foo_bar_group,not_going\n")
              file.rewind
              file
            }

            let(:empty_file) {
              file = Tempfile.new("invalid.pdf")
              file.rewind
              file
            }

            context 'current user can manage the event' do
              context 'no file is given' do
                it 'returns an error' do
                  post "/discourse-post-event/events/#{event_1.id}/csv-bulk-invite.json"
                  expect(response.parsed_body['error_type']).to eq('invalid_parameters')
                end
              end

              context 'empty file is given' do
                it 'returns an error' do
                  post "/discourse-post-event/events/#{event_1.id}/csv-bulk-invite.json", { params: { file: fixture_file_upload(empty_file) } }
                  expect(response.status).to eq(422)
                end
              end

              context 'a valid file is given' do
                before do
                  Jobs.run_later!
                end

                it 'enqueues the job and returns 200' do
                  expect_enqueued_with(job: :discourse_post_event_bulk_invite, args: {
                    "event_id" => event_1.id,
                    "invitees" => [
                      { 'identifier' => 'bob', 'attendance' => 'going' },
                      { 'identifier' => 'sam', 'attendance' => 'interested' },
                      { 'identifier' => 'the_foo_bar_group', 'attendance' => 'not_going' }
                    ],
                    "current_user_id" => user.id
                  }) do
                    post "/discourse-post-event/events/#{event_1.id}/csv-bulk-invite.json", { params: { file: fixture_file_upload(valid_file) } }
                  end

                  expect(response.status).to eq(200)
                end
              end
            end

            context 'current user can’t manage the event' do
              let(:lurker) { Fabricate(:user) }

              before do
                sign_in(lurker)
              end

              it 'returns an error' do
                post "/discourse-post-event/events/#{event_1.id}/csv-bulk-invite.json"
                expect(response.status).to eq(403)
              end
            end
          end

          context 'when doing bulk invite' do
            context 'current user can manage the event' do
              context 'no invitees is given' do
                it 'returns an error' do
                  post "/discourse-post-event/events/#{event_1.id}/bulk-invite.json"
                  expect(response.parsed_body['error_type']).to eq('invalid_parameters')
                end
              end

              context 'empty invitees are given' do
                it 'returns an error' do
                  post "/discourse-post-event/events/#{event_1.id}/bulk-invite.json", { params: { invitees: [] } }
                  expect(response.status).to eq(400)
                end
              end

              context 'valid invitees are given' do
                before do
                  Jobs.run_later!
                end

                it 'enqueues the job and returns 200' do
                  expect_enqueued_with(job: :discourse_post_event_bulk_invite, args: {
                    "event_id" => event_1.id,
                    "invitees" => [
                      { 'identifier' => 'bob', 'attendance' => 'going' },
                      { 'identifier' => 'sam', 'attendance' => 'interested' },
                      { 'identifier' => 'the_foo_bar_group', 'attendance' => 'not_going' }
                    ],
                    "current_user_id" => user.id
                  }) do
                    post "/discourse-post-event/events/#{event_1.id}/bulk-invite.json", { params: { invitees: [
                      { 'identifier' => 'bob', 'attendance' => 'going' },
                      { 'identifier' => 'sam', 'attendance' => 'interested' },
                      { 'identifier' => 'the_foo_bar_group', 'attendance' => 'not_going' }
                    ] } }
                  end

                  expect(response.status).to eq(200)
                end
              end
            end

            context 'current user can’t manage the event' do
              let(:lurker) { Fabricate(:user) }

              before do
                sign_in(lurker)
              end

              it 'returns an error' do
                post "/discourse-post-event/events/#{event_1.id}/bulk-invite.json"
                expect(response.status).to eq(403)
              end
            end
          end
        end

        context 'acting user has created the event' do
          it 'destroys a event' do
            expect(event_1.persisted?).to be(true)

            messages = MessageBus.track_publish do
              delete "/discourse-post-event/events/#{event_1.id}.json"
            end
            expect(messages.count).to eq(1)
            message = messages.first
            expect(message.channel).to eq("/discourse-post-event/#{event_1.post.topic_id}")
            expect(message.data[:id]).to eq(event_1.id)
            expect(response.status).to eq(200)
            expect(Event).to_not exist(id: event_1.id)
          end
        end

        context 'acting user has not created the event' do
          let(:lurker) { Fabricate(:user) }

          before do
            sign_in(lurker)
          end

          it 'doesn’t destroy the event' do
            expect(event_1.persisted?).to be(true)
            delete "/discourse-post-event/events/#{event_1.id}.json"
            expect(response.status).to eq(403)
            expect(Event).to exist(id: event_1.id)
          end
        end

        context 'when watching user is not logged' do
          before do
            sign_out
          end

          context 'when topic is public' do
            it 'can see the event' do
              get "/discourse-post-event/events/#{event_1.id}.json"

              expect(response.status).to eq(200)
            end
          end

          context 'when topic is not public' do
            before do
              event_1.post.topic.convert_to_private_message(Discourse.system_user)
            end

            it 'can’t see the event' do
              get "/discourse-post-event/events/#{event_1.id}.json"

              expect(response.status).to eq(404)
            end
          end
        end

        context 'when filtering by category' do
          it 'can filter the event by category' do
            category = Fabricate(:category)
            topic = Fabricate(:topic, category: category)
            event_2 = Fabricate(:event, post: Fabricate(:post, post_number: 1, topic: topic))

            get "/discourse-post-event/events.json?category_id=#{category.id}"

            expect(response.status).to eq(200)
            events = response.parsed_body["events"]
            expect(events.length).to eq(1)
            expect(events[0]["id"]).to eq(event_2.id)
          end
        end
      end
    end
  end
end
