class InvitationMailer < ApplicationMailer
  def invite(invitation, token)
    @invitation = invitation
    @acceptance_url = new_invitation_acceptance_url(invitation_token: token)
    mail to: invitation.email, subject: "You've been invited to #{invitation.workspace.name} on Departures"
  end
end
