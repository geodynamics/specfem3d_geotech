module slope
!this module contains main slope stability routines
contains

!-------------------------------------------------------------------------------
! this is a main routine for slope stabiliy analysis
! this program was originally based on the book "Programming the finite element
! method" Smith and Griffiths (2004)
! AUTHOR
!   Hom Nath Gharti
! REVISION:
!   HNG, Jul 14,2011; HNG, Jul 11,2011; Apr 09,2010
subroutine slope3d(sum_file,format_str)
! import necessary libraries
use global
use string_library, only : parse_file
use math_constants
use gll_library
use shape_library
use math_library
use element,only:hex8_gnode
use elastic
use preprocess
use plastic_library
#if (USE_MPI)
use mpi_library
use ghost_library_mpi
use math_library_mpi
use solver_mpi
#else
use serial_library
use math_library_serial
use solver
#endif
use visual
use postprocess
implicit none
character(len=250),intent(in) :: sum_file
character(len=20),intent(in) :: format_str

integer :: i,ios,istat,j,neq
integer :: i_elmt,i_node,i_srf,ielmt,imat,inode
!real(kind=kreal),parameter :: two_third=two/r3
real(kind=kreal) :: detjac,dq1,dq2,dq3,dsbar,dt,f,fmax,lode_theta,sigm

real(kind=kreal) :: uerr,umax,uxmax
integer :: cg_iter,cg_tot,nl_iter,nl_tot
logical :: nl_isconv ! logical variable to check convergence of
! nonlinear (NL) iterations

real(kind=kreal) :: cmat(nst,nst),devp(nst),eps(nst),erate(nst),evp(nst),      &
flow(nst,nst),m1(nst,nst),m2(nst,nst),m3(nst,nst),effsigma(nst),sigma(nst)
! dynamic arrays
integer,allocatable::gdof_elmt(:,:),num(:),node_valency(:)
! factored parameters
real(kind=kreal),allocatable :: cohf_blk(:),nuf_blk(:),phif_blk(:),psif_blk(:),&
ymf_blk(:)
real(kind=kreal),allocatable::bodyload(:),bmat(:,:),bload(:),coord(:,:),       &
der(:,:),deriv(:,:),dprecon(:),eld(:),eload(:),evpt(:,:,:),                    &
extload(:),jac(:,:),load(:),nodalu(:,:),storekm(:,:,:),oldx(:),x(:),            &
stress_elmt(:,:,:),stress_global(:,:),scf(:),vmeps(:)
!,psigma(:,:),psigma0(:,:),taumax(:),nsigma(:)
integer,allocatable :: egdof(:) ! elemental global degree of freedom

real(kind=kreal),allocatable :: dshape_hex8(:,:,:)
real(kind=kreal),parameter :: jacobi_alpha=0.0_kreal,jacobi_beta=0.0_kreal
!double precision
real(kind=kreal),allocatable :: xigll(:),wxgll(:) !double precision
real(kind=kreal),allocatable :: etagll(:),wygll(:) !double precision
real(kind=kreal),allocatable :: zetagll(:),wzgll(:) !double precision
real(kind=kreal),allocatable :: gll_weights(:),gll_points(:,:)
real(kind=kreal),allocatable :: lagrange_gll(:,:),dlagrange_gll(:,:,:)

character(len=250) :: out_fname
character(len=20), parameter :: wild_char='********************'
character(len=80) :: destag ! this must be 80 characters long
integer :: npart

logical :: gravity,pseudoeq ! gravity load and pseudostatic load
real(kind=kreal),allocatable :: wpressure(:) ! water pressure
logical,allocatable :: submerged_node(:)

integer :: tot_neq,max_neq,min_neq
! number of active ghost partitions for a node
character(len=250) :: errtag ! error message
integer :: errcode

errtag=""; errcode=-1

! apply displacement boundary conditions
if(myrank==0)write(stdout,'(a)',advance='no')'applying BC...'
allocate(gdof(nndof,nnode),stat=istat)
if (istat/=0)then
  write(stdout,*)'ERROR: cannot allocate memory!'
  stop
endif
gdof=1
call apply_bc(neq,errcode,errtag)
if(errcode/=0)call error_stop(errtag)
if(myrank==0)write(stdout,*)'complete!'
!-------------------------------------

allocate(num(nenod),evpt(nst,ngll,nelmt),coord(ngnode,ndim),jac(ndim,ndim),    &
der(ndim,ngnode),deriv(ndim,nenod),bmat(nst,nedof),eld(nedof),bload(nedof),    &
eload(nedof),nodalu(nndof,nnode),egdof(nedof),stat=istat)
if (istat/=0)then
  write(stdout,*)'ERROR: cannot allocate memory!'
  stop
endif

tot_neq=sumscal(neq); max_neq=maxscal(neq); min_neq=minscal(neq)
if(myrank==0)then
  write(stdout,*)'degrees of freedoms => total:',tot_neq,' max:',max_neq,      &
  ' min:',min_neq
endif

! get GLL quadrature points and weights
allocate(xigll(ngllx),wxgll(ngllx),etagll(nglly),wygll(nglly),zetagll(ngllz),  &
wzgll(ngllz))
call zwgljd(xigll,wxgll,ngllx,jacobi_alpha,jacobi_beta)
call zwgljd(etagll,wygll,nglly,jacobi_alpha,jacobi_beta)
call zwgljd(zetagll,wzgll,ngllz,jacobi_alpha,jacobi_beta)

! get derivatives of shape functions for 8-noded hex
allocate(dshape_hex8(ndim,ngnode,ngll))
call dshape_function_hex8(ngnode,ngllx,nglly,ngllz,xigll,etagll,zetagll,       &
dshape_hex8)
deallocate(xigll,wxgll,etagll,wygll,zetagll,wzgll)
! compute gauss-lobatto-legendre quadrature information
allocate(gll_weights(ngll),gll_points(ndim,ngll),lagrange_gll(ngll,ngll),      &
dlagrange_gll(ndim,ngll,ngll))
call gll_quadrature(ndim,ngllx,nglly,ngllz,ngll,gll_points,gll_weights,        &
lagrange_gll,dlagrange_gll)
!--------------------------------

! store elemental global degrees of freedoms from nodal gdof
! this removes the repeated use of reshape later but it has larger
! size than gdof!!!
allocate(gdof_elmt(nedof,nelmt))
gdof_elmt=0
do i_elmt=1,nelmt
  gdof_elmt(:,i_elmt)=reshape(gdof(:,g_num(:,i_elmt)),(/nedof/))
enddo

! compute stiffness and body load
if(myrank==0)write(stdout,'(a)',advance='no')'preprocessing...'

allocate(stress_elmt(nst,ngll,nelmt))
! compute initial stress assuming elastic domain
stress_elmt=zero

allocate(extload(0:neq),dprecon(0:neq),storekm(nedof,nedof,nelmt),stat=istat)
! elastic(0:neq),
if (istat/=0)then
  write(stdout,*)'ERROR: cannot allocate memory!'
  stop
endif
extload=zero; gravity=.true.; pseudoeq=iseqload
call stiffness_bodyload(nelmt,neq,hex8_gnode,g_num,gdof_elmt,mat_id,gam_blk,   &
nu_blk,ym_blk,dshape_hex8,dlagrange_gll,gll_weights,storekm,dprecon,extload,   &
gravity,pseudoeq)

if(myrank==0)write(stdout,*)'complete!'

! apply traction boundary conditions
if(istraction)then
  if(myrank==0)write(*,'(a)',advance='no')'applying traction...'
  call apply_traction(hex8_gnode,neq,extload,errcode,errtag)
  if(errcode/=0)call error_stop(errtag)
  if(myrank==0)write(*,*)'complete!'
endif

! compute water pressure
if(iswater)then
  if(myrank==0)write(stdout,'(a)',advance='no')'computing water pressure...'
  allocate(wpressure(nnode),submerged_node(nnode))
  call compute_pressure(wpressure,submerged_node,errcode,errtag)
  if(errcode/=0)call error_stop(errtag)
  ! write pore pressure file

  ! open Ensight Gold data file to store data
  out_fname=trim(out_path)//trim(file_head)//trim(ptail)//'.por'
  npart=1;
  destag='Pore pressure'
  call write_ensight_pernode(out_fname,destag,npart,1,nnode,real(wpressure))
  if(myrank==0)write(stdout,*)'complete!'
endif

if(myrank==0)write(stdout,'(a)')'--------------------------------------------'

! prepare ghost partitions for the communication
call prepare_ghost()

! prepare ghost partitions gdof
call prepare_ghost_gdof()

! assemble from ghost partitions
call assemble_ghosts(neq,dprecon,dprecon)
dprecon(1:)=one/dprecon(1:); dprecon(0)=zero

allocate(stress_global(nst,nnode),vmeps(nnode))
allocate(scf(nnode))
!,psigma(ndim,nnode),psigma0(ndim,nnode),taumax(nnode),nsigma(nnode))
allocate(node_valency(nnode))

! compute node valency only once
node_valency=0
do i_elmt=1,nelmt
  num=g_num(:,i_elmt)
  node_valency(num)=node_valency(num)+1
enddo

! open summary file
open(unit=10,file=trim(sum_file),status='old',position='append',action='write',&
iostat=ios)
write(10,*)'CG_MAXITER, CG_TOL, NL_MAXITER, NL_TOL'
write(10,*)cg_maxiter,cg_tol,nl_maxiter,nl_tol
write(10,*)'Number of SRFs'
write(10,*)nsrf
write(10,*)'SRF, CGITER, NLITER, UXMAX, UMAX, fmax'
close(10)

allocate(bodyload(0:neq),load(0:neq),x(0:neq),oldx(0:neq),stat=istat)
! elastic(0:neq),
if (istat/=0)then
  write(stdout,*)'ERROR: cannot allocate memory!'
  stop
endif

allocate(cohf_blk(nmatblk),nuf_blk(nmatblk),phif_blk(nmatblk),                 &
psif_blk(nmatblk),ymf_blk(nmatblk))

if(myrank==0)then
  write(stdout,'(a,e12.4,a,i5)')'CG_TOL:',cg_tol,' CG_MAXITER:',cg_maxiter
  write(stdout,'(a,e12.4,a,i5)')'NL_TOL:',nl_tol,' NL_MAXITER:',nl_maxiter
  write(stdout,'(a)',advance='no')'SRFs:'
  do i_srf=1,nsrf
    write(stdout,'(f7.4,1x)',advance='no')srf(i_srf)
  enddo
  write(stdout,'(/,a)')'--------------------------------------------'
endif

! strength reduction (factor of safety) loop
srf_loop: do i_srf=1,nsrf
  if(myrank==0)write(stdout,'(/,a,f7.4)')'SRF:',srf(i_srf)

   ! initialize
  nodalu=zero; vmeps=zero
  stress_elmt=zero; scf=inftol

  ! strength reduction
  call strength_reduction(srf(i_srf),phinu,nmatblk,coh_blk,nu_blk,phi_blk,     &
  psi_blk,cohf_blk,nuf_blk,phif_blk,psif_blk,istat)

  ! compute minimum pseudo-time step for viscoplasticity
  dt=dt_viscoplas(nmatblk,nuf_blk,phif_blk,ym_blk)

  ! recompute stiffness if either of nu and ym has changed
  if(istat==1)then
    ! in future this should be changed so that only the elements with changed
    ! material properties are involved
    dprecon=zero
    call stiffness_bodyload(nelmt,neq,hex8_gnode,g_num,gdof_elmt,mat_id,       &
    gam_blk,nuf_blk,ym_blk,dshape_hex8,dlagrange_gll,gll_weights,storekm,      &
    dprecon)

    ! assemble from ghost partitions
    call assemble_ghosts(neq,dprecon,dprecon)
    dprecon(1:)=one/dprecon(1:); dprecon(0)=zero
  endif

  ! find global dt
  dt=minscal(dt)

  cg_tot=0; nl_tot=0
  ! load incremental loop
  !if(myrank==0)write(stdout,'(a,i10)')' total load increments:',ninc
  !extload=extload/ninc
  !load_increment: do i_inc=1,ninc

  bodyload=zero; evpt=zero
  x=zero; oldx=zero

  ! plastic iteration loop
  plastic: do nl_iter=1,nl_maxiter
    fmax=zero

    load=extload+bodyload
    load(0)=zero

    ! pcg solver
    !x=zero
    call pcg_solver(neq,nelmt,storekm,x,load,dprecon,gdof_elmt,cg_iter,        &
    errcode,errtag)
    if(errcode/=0)call error_stop(errtag)
    cg_tot=cg_tot+cg_iter
    x(0)=zero

    if(allelastic)then
      call elastic_stress(nelmt,neq,hex8_gnode,g_num,gdof_elmt,mat_id,         &
      dshape_hex8,dlagrange_gll,x,stress_elmt)

      exit plastic
    endif

    ! check plastic convergence
    uerr=maxvec(abs(x-oldx))/maxvec(abs(x))
    oldx=x
    nl_isconv=uerr.le.nl_tol

    ! compute stress and check failure
    do i_elmt=1,nelmt
      ielmt=i_elmt
      imat=mat_id(ielmt)

      call compute_cmat(cmat,ym_blk(imat),nuf_blk(imat))
      num=g_num(:,ielmt)
      coord=transpose(g_coord(:,num(hex8_gnode)))
      egdof=gdof_elmt(:,ielmt)
      eld=x(egdof)

      bload=zero
      do i=1,ngll ! loop over integration points
        jac=matmul(dshape_hex8(:,:,i),coord)
        detjac=determinant(jac)
        call invert(jac)

        deriv=matmul(jac,dlagrange_gll(:,i,:))
        call compute_bmat(deriv,bmat)
        eps=matmul(bmat,eld)
        eps=eps-evpt(:,i,ielmt)
        sigma=matmul(cmat,eps)

        ! compute effective stress
        effsigma=sigma+stress_elmt(:,i,ielmt)
        if(iswater)then
          if(submerged_node(num(i)))then
             ! water pressure is compressive (negative)
            effsigma(1:3)=effsigma(1:3)+wpressure(num(i))
          endif
        endif

        !effsigma=effsigma+stress_elmt(:,i,ielmt)
        call stress_invariant(effsigma,sigm,dsbar,lode_theta)
        ! check whether yield is violated
        call mohcouf(phif_blk(imat),cohf_blk(imat),sigm,dsbar,lode_theta,f)
        if(f>fmax)fmax=f

        if(f>=zero)then !.or.(nl_isconv.or.nl_iter==nl_maxiter))then
          call mohcouq(psif_blk(imat),dsbar,lode_theta,dq1,dq2,dq3)
          call formm(effsigma,m1,m2,m3)
          flow=f*(m1*dq1+m2*dq2+m3*dq3)

          erate=matmul(flow,effsigma)
          evp=erate*dt
          evpt(:,i,ielmt)=evpt(:,i,ielmt)+evp
          devp=matmul(cmat,evp)
          ! if not converged we need body load for next iteration
          if(.not.nl_isconv .and. nl_iter/=nl_maxiter)then
            !devp(1:3)=devp(1:3)-wpressure(num(i))
            eload=matmul(devp,bmat)
            bload=bload+eload*detjac*gll_weights(i)
          end if
        end if
        if(nl_isconv.or.nl_iter==nl_maxiter)then
          devp=sigma
          ! compute von Mises effective plastic strain
          !vmeps(num(i))=vmeps(num(i))+sqrt(two_third*                         &
          !dot_product(evpt(:,i,ielmt),evpt(:,i,ielmt)))
          ! update stresses
          stress_elmt(:,i,ielmt)=effsigma
          !phif_blkr=atan(tnph/srf(i_srf))
          !sf=(sigm*sin(phif_blkr)-cohf_blk*cos(phif_blkr))/&
          !(-dsbar*(cos(lode_theta)/      &
          !sqrt(r3)-sin(lode_theta)*sin(phif_blkr)/r3))
          !if(sf<scf(num(i)))scf(num(i))=sf
        endif
      end do ! i_gll

      if(nl_isconv .or. nl_iter==nl_maxiter)cycle
      ! compute total body load vector
      bodyload(egdof)=bodyload(egdof)+bload
    end do ! i_elmt
    bodyload(0)=zero
    fmax=maxscal(fmax)
    uxmax=maxvec(abs(x))
    if(myrank==0)then
      write(stdout,'(a,i4,a,f12.6,a,f12.6,a,f12.6)') &
      ' nl_iter:',nl_iter,' f_max:',fmax,' uerr:',uerr,' umax:',uxmax
    endif
    if(nl_isconv.or.nl_iter==nl_maxiter)exit
  end do plastic ! plastic iteration
  ! check if the plastic iteration did not converge
  if(nl_iter>=nl_maxiter .and. .not.nl_isconv)then
    write(stdout,*)'WARNING: nonconvergence in nonlinear iterations!'
    write(stdout,*)'desired tolerance:',nl_tol,' achieved tolerance:',uerr
  endif

  nl_tot=nl_tot+nl_iter
  ! nodal displacement
  do i=1,nndof
    do j=1,nnode
      if(gdof(i,j)/=0)then
        nodalu(i,j)=nodalu(i,j)+x(gdof(i,j)) !-elastic(gdof(i,j))
      endif
    enddo
  enddo
  !enddo load_increment ! load increment loop

  ! write summary
  uxmax=maxvec(abs(reshape(nodalu,(/nndof*nnode/))))
  umax=maxvec(sqrt(nodalu(1,:)*nodalu(1,:)+ &
  nodalu(2,:)*nodalu(2,:)+nodalu(3,:)*nodalu(3,:)))
  open(10,file=trim(sum_file),status='old',position='append',action='write')
  write(10,*)srf(i_srf),cg_tot,nl_tot,uxmax,umax,fmax
  close(10)

  ! compute average effective strain
  do i_node=1,nnode
    inode=i_node
    vmeps(inode)=vmeps(inode)/real(node_valency(inode),kreal)
  enddo

  ! compute stress_global
  stress_global=zero
  do i_elmt=1,nelmt
    ielmt=i_elmt
    num=g_num(:,ielmt)
    stress_global(:,num)=stress_global(:,num)+stress_elmt(:,:,ielmt)
  enddo

  ! compute average stress at sharing nodes
  do i_node=1,nnode
    inode=i_node
    stress_global(:,inode)=stress_global(:,inode)/real(node_valency(inode),    &
                                                      kreal)
  enddo

  call save_data(format_str,i_srf,nnode,nodalu,scf,vmeps,stress_global)

  if(nl_iter==nl_maxiter)exit

enddo srf_loop ! i_srf safety factor loop
deallocate(mat_id,gam_blk,ym_blk,coh_blk,nu_blk,phi_blk,psi_blk,srf)
deallocate(g_coord,g_num)
deallocate(load,bodyload,extload,oldx,x,dprecon,storekm,stat=istat)
call free_ghost()

return
end subroutine slope3d
!===============================================================================
end module slope
!===============================================================================
