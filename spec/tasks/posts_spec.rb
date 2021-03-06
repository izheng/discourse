require 'rails_helper'
require 'highline/import'
require 'highline/simulate'

RSpec.describe "Post rake tasks" do
  let!(:post) { Fabricate(:post, raw: 'The quick brown fox jumps over the lazy dog') }
  let!(:tricky_post) { Fabricate(:post, raw: 'Today ^Today') }

  before do
    Rake::Task.clear
    Discourse::Application.load_tasks
    STDOUT.stubs(:write)
  end

  describe 'remap' do
    it 'should remap posts' do
      HighLine::Simulate.with('y') do
        Rake::Task['posts:remap'].invoke("brown", "red")
      end

      post.reload
      expect(post.raw).to eq('The quick red fox jumps over the lazy dog')
    end

    context 'when type == string' do
      it 'remaps input as string' do
        HighLine::Simulate.with('y') do
          Rake::Task['posts:remap'].invoke('^Today', 'Yesterday', 'string')
        end

        expect(tricky_post.reload.raw).to eq('Today Yesterday')
      end
    end

    context 'when type == regex' do
      it 'remaps input as regex' do
        HighLine::Simulate.with('y') do
          Rake::Task['posts:remap'].invoke('^Today', 'Yesterday', 'regex')
        end

        expect(tricky_post.reload.raw).to eq('Yesterday ^Today')
      end
    end
  end

  describe 'rebake_match' do
    it 'rebakes matched posts' do
      post.update_attributes(cooked: '')

      HighLine::Simulate.with('y') do
        Rake::Task['posts:rebake_match'].invoke('brown')
      end

      expect(post.reload.cooked).to eq('<p>The quick brown fox jumps over the lazy dog</p>')
    end
  end

  describe 'missing_uploads' do
    let(:upload) { Fabricate(:upload) }
    let(:optimized) { Fabricate(:optimized_image, url: '/uploads/default/optimized/1X/d1c2d40ab994e8410c_100x200.png') }

    it 'should create post custom field for missing upload' do
      Fabricate(:post, cooked: "A sample post <img src='#{upload.url}'>")
      upload.destroy!

      Rake::Task['posts:missing_uploads'].invoke

      field = PostCustomField.find_by(name: "missing_uploads")
      expect(field).to be_present
      expect(field.value).to eq(upload.url)
    end
  end
end
