defmodule ShlinkedinWeb.GroupLive.Show do
  use ShlinkedinWeb, :live_view

  alias Shlinkedin.Groups
  alias Shlinkedin.Groups.Invite
  alias Shlinkedin.Timeline
  alias Shlinkedin.Timeline.Post
  alias Shlinkedin.Timeline.Comment

  @impl true
  def mount(%{"id" => id}, session, socket) do
    socket = is_user(session, socket)
    group = Groups.get_group!(id)

    if connected?(socket) do
      Timeline.subscribe()
    end

    {:ok,
     socket
     |> assign(
       show_menu: false,
       group: group,
       page_title: group.title,
       member_status: is_member?(socket.assigns.profile, group),
       members: members(group),
       admins: Shlinkedin.Groups.list_admins(group),
       member_ranking: Shlinkedin.Groups.get_member_ranking(socket.assigns.profile, group),
       page: 1,
       per_page: 5,
       like_map: Timeline.like_map(),
       comment_like_map: Timeline.comment_like_map(),
       num_show_comments: 3
     )
     |> fetch_posts(), temporary_assigns: [posts: []]}
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :show, _params) do
    socket
  end

  defp apply_action(socket, :invite, %{"id" => id}) do
    socket
    |> assign(:page_title, "Invite to #{socket.assigns.group.title}")
    |> assign(:profile, socket.assigns.profile)
    |> assign(:invite, %Invite{})
    |> assign(:group, Groups.get_group!(id))
  end

  defp apply_action(socket, :edit_group, %{"id" => id}) do
    socket
    |> assign(:page_title, "Edit Group")
    |> assign(:group, Groups.get_group!(id))
  end

  defp apply_action(socket, :new, _params) do
    socket
    |> assign(:page_title, "Create a post in #{socket.assigns.group.title}")
    |> assign(:post, %Post{group_id: socket.assigns.group.id})
  end

  defp apply_action(socket, :show_likes, %{"post_id" => id}) do
    post = Timeline.get_post_preload_profile(id)

    socket
    |> assign(:page_title, "Reactions")
    |> assign(
      :grouped_likes,
      Timeline.list_likes(post)
      |> Enum.group_by(&%{name: &1.name, photo_url: &1.photo_url, slug: &1.slug})
    )
  end

  defp apply_action(socket, :show_comment_likes, %{"comment_id" => comment_id}) do
    comment = Timeline.get_comment!(comment_id)

    socket
    |> assign(:page_title, "Comment Reactions")
    |> assign(
      :grouped_likes,
      Timeline.list_comment_likes(comment)
      |> Enum.group_by(&%{name: &1.name, photo_url: &1.photo_url, slug: &1.slug})
    )
    |> assign(:comment, comment)
  end

  defp apply_action(socket, :new_comment, %{"post_id" => id, "reply_to" => username}) do
    post = Timeline.get_post_preload_profile(id)

    socket
    |> assign(:page_title, "Reply to #{post.profile.persona_name}'s comment")
    |> assign(:reply_to, username)
    |> assign(:comments, [])
    |> assign(:comment, %Comment{})
    |> assign(:post, post)
  end

  defp apply_action(socket, :new_comment, %{"post_id" => id}) do
    post = Timeline.get_post_preload_profile(id)

    socket
    |> assign(:page_title, "Comment")
    |> assign(:reply_to, nil)
    |> assign(:comments, [])
    |> assign(:comment, %Comment{})
    |> assign(:post, post)
  end

  defp fetch_posts(%{assigns: %{page: page, per_page: per, group: group}} = socket) do
    assign(socket,
      posts: Timeline.list_group_posts([paginate: %{page: page, per_page: per}], group)
    )
  end

  def handle_event("load-more", _, %{assigns: assigns} = socket) do
    {:noreply, socket |> assign(page: assigns.page + 1) |> fetch_posts()}
  end

  def handle_event("join-group", %{"id" => id}, socket) do
    group = Groups.get_group!(id)
    Groups.join_group(socket.assigns.profile, group, %{ranking: "member"})

    {:noreply, socket |> assign(member_status: is_member?(socket.assigns.profile, group))}
  end

  def handle_event("show-menu", _, socket) do
    socket = assign(socket, show_menu: !socket.assigns.show_menu)
    {:noreply, socket}
  end

  def handle_event("hide-menu", _, socket) do
    socket = assign(socket, show_menu: false)
    {:noreply, socket}
  end

  @impl true
  def handle_event("leave-group", _, socket) do
    Groups.leave_group(socket.assigns.profile, socket.assigns.group)

    {:noreply,
     socket
     |> put_flash(:info, "You left the group")
     |> push_redirect(to: Routes.group_index_path(socket, :index))}
  end

  @impl true
  def handle_event("delete", %{"id" => id}, socket) do
    post = Timeline.get_post!(id)
    {:ok, _} = Timeline.delete_post(post)

    {:noreply,
     assign(
       socket,
       :posts,
       Timeline.list_posts(socket.assigns.profile, paginate: %{page: 1, per_page: 5})
     )}
  end

  @impl true
  def handle_event("delete-comment", %{"id" => id}, socket) do
    comment = Timeline.get_comment!(id)
    {:ok, _} = Timeline.delete_comment(comment)

    {:noreply,
     socket
     |> put_flash(:info, "Comment deleted")
     |> push_redirect(to: Routes.group_show_path(socket, :show, socket.assigns.group.id))}
  end

  @impl true
  def handle_event("delete-group", %{"id" => id}, socket) do
    group = Groups.get_group!(id)
    {:ok, _} = Groups.delete_group(group)

    {:noreply,
     socket
     |> put_flash(:info, "Group has been deleted")
     |> push_redirect(to: Routes.group_index_path(socket, :index))}
  end

  def handle_event("invite", %{"id" => id}, socket) do
    to_profile = Shlinkedin.Profiles.get_profile_by_profile_id(id)
    Groups.send_invite(socket.assigns.profile, to_profile, socket.assigns.group)

    send_update(ShlinkedinWeb.GroupLive.InviteRow,
      id: to_profile.id,
      member_status: member_status(to_profile, socket.assigns.group)
    )

    {:noreply, socket}
  end

  @doc """
  Gets the text for the invite button.
  """
  defp member_status(profile, group) do
    cond do
      Shlinkedin.Groups.is_member?(profile, group) -> "Member"
      Shlinkedin.Groups.is_invited?(profile, group) -> "Invited"
      true -> "Invite"
    end
  end

  defp is_member?(profile, group) do
    Shlinkedin.Groups.is_member?(profile, group)
  end

  defp members(group) do
    Shlinkedin.Groups.list_members(group)
  end

  @impl true
  def handle_info({:post_created, post}, socket) do
    {:noreply, update(socket, :posts, fn posts -> [post | posts] end)}
  end

  @impl true
  def handle_info({:post_updated, post}, socket) do
    {:noreply, update(socket, :posts, fn posts -> [post | posts] end)}
  end

  @impl true
  def handle_info({:post_deleted, post}, socket) do
    {:noreply, update(socket, :posts, fn posts -> [post | posts] end)}
  end
end
